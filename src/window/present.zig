//! Presenting frames (`gfx.Frame`s) in a window with a renderer: on the GPU
//! straight into the window's buffer (a dmabuf on Wayland, or the Metal
//! layer on macOS) if they can, or else into its buffer on the CPU; only
//! what the buffer's age says has to be drawn, and then shown (only what
//! changed).
//!
//! That is done on the caller's thread, or on a render thread of the
//! presenter's own (`startThread`): then the window is asked for its
//! buffer, and shown it, on the caller's thread (windows need not be
//! thread-safe), and only the renderer runs on the render thread, a frame
//! at a time, while the UI makes the next. Everything the renderer does
//! goes there (`call`), so it is used from one thread only. The render
//! thread runs none of the app's code, and does not use its `Io`.
//!
//! Frames made to outlive the UI's next one (`owned_frames`, as the render
//! thread needs them) are drawn with the presenter's own copies of what
//! they carry: the glyph atlas, and the images (kept while they are drawn,
//! by `gfx.frame.Residency`).

const std = @import("std");
const gfx = @import("gfx");
const window_mod = @import("window.zig");
const sys = @import("sys.zig");

const Window = window_mod.Window;
const Viewport = gfx.Viewport;

pub const Presenter = struct {
    /// What draws the frames (none: they cannot be presented).
    renderer: ?gfx.Renderer = null,
    /// The renderer could not draw straight into the window's buffers, so
    /// frames are drawn into them on the CPU.
    no_direct: bool = false,
    /// The UI makes its frames outlive the next (`gfx.Frame.owned`).
    owned_frames: bool = false,
    /// For those: the glyph atlas as they say it is, the images they draw
    /// (each with its pixels), which those are, and what made them.
    atlas: ?*gfx.Atlas = null,
    images: std.AutoHashMapUnmanaged(u64, *gfx.Image) = .empty,
    residency: gfx.frame.Residency = .{},
    gpa: ?std.mem.Allocator = null,
    /// The render thread, if it has one; what it waits through (the
    /// caller's `Io`); and the frame it was given and is not yet shown,
    /// with the window it is shown in.
    thread: ?*RenderThread = null,
    io: std.Io = undefined,
    inflight: gfx.Frame = undefined,
    inflight_job: FrameJob = undefined,
    inflight_win: ?Window = null,

    /// Where a frame is drawn.
    pub const Target = union(enum) {
        cpu: gfx.software.Image,
        dmabuf: gfx.DmabufTarget,
        metal: gfx.MetalTarget,
    };

    /// A frame to draw: into what, and where (by the buffer's age).
    const FrameJob = struct {
        frame: *const gfx.Frame,
        target: Target,
        vps: []const Viewport,
    };

    pub fn deinit(p: *Presenter) void {
        if (p.thread) |t| {
            // What it was drawing is not shown.
            p.waitDone() catch {};
            t.stop();
            p.thread = null;
            p.inflight_win = null;
        }
        const gpa = p.gpa orelse return;
        if (p.atlas) |a| {
            a.deinit();
            gpa.destroy(a);
        }
        var it = p.images.valueIterator();
        while (it.next()) |img| freeImage(gpa, img.*);
        p.images.deinit(gpa);
        p.residency.deinit(gpa);
        p.* = .{ .renderer = p.renderer, .owned_frames = p.owned_frames };
    }

    /// Draws frames on a render thread of its own from now on (and asks
    /// for frames that outlive the next, as it needs them), waiting for it
    /// through `io` (the caller's). It allocates with `gpa`.
    pub fn startThread(p: *Presenter, gpa: std.mem.Allocator, io: std.Io) !void {
        if (p.thread != null) return;
        p.thread = try RenderThread.start(gpa, p);
        p.io = io;
        p.owned_frames = true;
    }

    /// Whether a frame is being drawn on the render thread (and so no
    /// other may be given until it is shown: see `collect`).
    pub fn busy(p: *const Presenter) bool {
        return p.inflight_win != null;
    }

    /// What is read when the render thread has drawn a frame, for the
    /// window to wait on with its events (none without a render thread).
    pub fn source(p: *Presenter) ?window_mod.Source {
        const t = p.thread orelse return null;
        return .ofWake(&t.done);
    }

    /// Shows the frame the render thread has drawn, if it has; whether it
    /// did.
    pub fn collect(p: *Presenter) !bool {
        const t = p.thread orelse return false;
        if (p.inflight_win == null or t.state.load(.acquire) != .done) return false;
        try p.show();
        return true;
    }

    /// Waits for the frame being drawn on the render thread, and shows it
    /// (nothing without one).
    pub fn flush(p: *Presenter) !void {
        if (p.inflight_win == null) return;
        try p.waitDone();
        try p.show();
    }

    /// Waits until frame `frame_no` (and those before) has been presented,
    /// so that the UI may draw in what it used again.
    pub fn waitRetired(p: *Presenter, frame_no: u64) void {
        if (p.inflight_win != null and p.inflight.frame_no <= frame_no) p.flush() catch {};
    }

    /// Draws `frame` into the window's next buffer, and shows it (on the
    /// render thread, if it has one: shown once drawn, by `collect`, or
    /// `flush`, or giving it the next).
    pub fn present(p: *Presenter, win: Window, frame: *const gfx.Frame) !void {
        try p.flush();
        try p.adopt(frame);
        const r = p.renderer orelse return error.NoRenderer;
        if (p.thread) |t| {
            p.inflight = frame.*;
            p.inflight_job = try p.acquire(win, &p.inflight);
            p.inflight_win = win;
            t.submit(.{ .frame = &p.inflight_job });
            // Shown in the window's transaction (as it is resized), so
            // drawn and shown now, on this thread.
            if (p.inflight_job.target == .metal and p.inflight_job.target.metal.held != null) try p.flush();
            return;
        }
        var job = try p.acquire(win, frame);
        render(r, &job) catch |e| {
            if (job.target == .cpu) return e;
            // Drawn on the CPU instead, from now on.
            p.no_direct = true;
            job = try p.acquire(win, frame);
            try render(r, &job);
        };
        win.finishFrame(job.vps);
        try win.showDamaged(frame.damage.slice());
    }

    /// The window's next buffer to draw `frame` in (on the GPU straight
    /// into it, if the renderer can), and what of it to draw.
    fn acquire(p: *const Presenter, win: Window, frame: *const gfx.Frame) !FrameJob {
        if (p.directRenderer()) |dr| {
            if (dr.hasDmabuf()) if (win.beginDmabufFrame()) |t|
                return .{ .frame = frame, .target = .{ .dmabuf = t }, .vps = frame.repaint(win.bufferAge()) };
            if (dr.hasMetal()) if (win.beginMetalFrame()) |t|
                return .{ .frame = frame, .target = .{ .metal = t }, .vps = frame.repaint(win.bufferAge()) };
        }
        const img = try win.beginFrame();
        return .{ .frame = frame, .target = .{ .cpu = img }, .vps = frame.repaint(win.bufferAge()) };
    }

    /// Draws a frame (on whichever thread draws).
    fn render(r: gfx.Renderer, job: *const FrameJob) !void {
        const f = job.frame;
        var buf: [2][gfx.renderer.max_uncovered]Viewport = undefined;
        const clears = gfx.renderer.uncovered(&buf, job.vps, f.segments);
        switch (job.target) {
            .cpu => |img| {
                img.clearViewports(f.clear, clears);
                var target = img;
                try r.renderSegments(f.canvases, f.segments, &target, job.vps);
            },
            .dmabuf => |*t| try r.renderDmabuf(f.canvases, f.segments, t, f.clear, clears, job.vps),
            .metal => |*t| try r.renderMetal(f.canvases, f.segments, t, f.clear, clears, job.vps),
        }
    }

    /// Shows the frame the render thread has drawn (drawn again on the CPU
    /// first, if the GPU could not draw it).
    fn show(p: *Presenter) !void {
        const t = p.thread.?;
        const win = p.inflight_win.?;
        defer p.inflight_win = null;
        const failed = t.result;
        t.state.store(.idle, .release);
        if (failed) |e| {
            if (p.inflight_job.target == .cpu) return e;
            p.no_direct = true;
            p.inflight_job = try p.acquire(win, &p.inflight);
            t.submit(.{ .frame = &p.inflight_job });
            try p.waitDone();
            const again = t.result;
            t.state.store(.idle, .release);
            if (again) |e2| return e2;
        }
        win.finishFrame(p.inflight_job.vps);
        try win.showDamaged(p.inflight.damage.slice());
    }

    /// Waits (through `io`) until the render thread has done what it was
    /// given.
    fn waitDone(p: *Presenter) !void {
        const t = p.thread orelse return;
        while (t.state.load(.acquire) == .queued) {
            _ = p.io.operateTimeout(t.done.readOperation(), .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }) catch |e| switch (e) {
                error.Timeout => {},
                else => return e,
            };
        }
    }

    /// Runs `f(ctx)` where the renderer is used (on the render thread, if
    /// it has one, waiting for it), as everything that uses the renderer
    /// must be.
    pub fn call(p: *Presenter, ctx: *anyopaque, f: *const fn (ctx: *anyopaque) anyerror!void) !void {
        const t = p.thread orelse return f(ctx);
        try p.flush();
        t.submit(.{ .call = .{ .ctx = ctx, .f = f } });
        try p.waitDone();
        const failed = t.result;
        t.state.store(.idle, .release);
        if (failed) |e| return e;
    }

    /// Draws `frame` whole into popup `id`'s next buffer, and shows it;
    /// false if the popup has no buffer to draw into yet.
    pub fn presentPopup(p: *Presenter, win: Window, id: u32, frame: *const gfx.Frame) !bool {
        try p.flush();
        try p.adopt(frame);
        const r = p.renderer orelse return error.NoRenderer;
        var img = (try win.beginPopupFrame(id)) orelse return false;
        img.clear(frame.clear);
        const Draw = struct {
            r: gfx.Renderer,
            frame: *const gfx.Frame,
            img: *gfx.software.Image,
            fn f(ctx: *anyopaque) anyerror!void {
                const d: *@This() = @ptrCast(@alignCast(ctx));
                try d.r.prepare(d.frame.canvases);
                try d.r.render(d.frame.segments, d.img, null);
            }
        };
        var draw: Draw = .{ .r = r, .frame = frame, .img = &img };
        try p.call(&draw, Draw.f);
        try win.showPopup(id);
        return true;
    }

    /// Takes what an owned frame carries, and points its canvases at the
    /// presenter's copies of the atlas and the images.
    fn adopt(p: *Presenter, frame: *const gfx.Frame) !void {
        const o = frame.owned orelse return;
        const gpa = o.gpa;
        p.gpa = gpa;
        p.residency.begin(gpa, frame.frame_no, p, evict);
        // Its images are the presenter's, whatever happens next.
        for (o.new_images, 0..) |img, i| {
            const kept = gpa.create(gfx.Image) catch |e| {
                for (o.new_images[i..]) |rest| gpa.free(rest.pixels);
                return e;
            };
            kept.* = img;
            const old = p.images.fetchPut(gpa, img.id, kept) catch |e| {
                gpa.destroy(kept);
                for (o.new_images[i..]) |rest| gpa.free(rest.pixels);
                return e;
            };
            if (old) |kv| freeImage(gpa, kv.value);
        }
        if (o.atlas_rows) |rows| {
            if (p.atlas == null) {
                const a = try gpa.create(gfx.Atlas);
                a.* = gfx.Atlas.init(gpa) catch |e| {
                    gpa.destroy(a);
                    return e;
                };
                p.atlas = a;
            }
            const a = p.atlas.?;
            const w = gfx.atlas.width;
            @memcpy(a.pixels[rows.y0 * w ..][0..rows.rows.len], rows.rows);
            const y1: u32 = @intCast(rows.y0 + rows.rows.len / w);
            a.dirty = gfx.Atlas.unite(a.dirty, .{ .x0 = 0, .y0 = rows.y0, .x1 = w, .y1 = y1 });
        }
        for (o.canvases) |c| {
            if (c.atlas != null) c.atlas = p.atlas;
            for (c.batches.items) |*b| if (b.image != null) {
                b.image = p.images.get(b.image_id);
                try p.residency.use(gpa, b.image_id);
            };
        }
    }

    fn evict(p: *Presenter, id: u64) void {
        const kv = p.images.fetchRemove(id) orelse return;
        freeImage(p.gpa.?, kv.value);
    }

    fn freeImage(gpa: std.mem.Allocator, img: *gfx.Image) void {
        gpa.free(img.pixels);
        gpa.destroy(img);
    }

    /// The renderer, if it may draw frames straight into the window's
    /// dmabufs or Metal layer (it has not failed to).
    fn directRenderer(p: *const Presenter) ?gfx.Renderer {
        if (p.no_direct) return null;
        const r = p.renderer orelse return null;
        return if (r.hasDmabuf() or r.hasMetal()) r else null;
    }
};

/// A thread that draws frames (and does what else the renderer is asked),
/// one thing at a time: given it by the UI's thread (`submit`), which waits
/// for it to be done (`done`, readable then) before giving it the next.
const RenderThread = struct {
    gpa: std.mem.Allocator,
    presenter: *const Presenter,
    thread: std.Thread = undefined,
    /// Readable when it has something to do, and when it has done it.
    ready: sys.Wake,
    done: sys.Wake,
    state: std.atomic.Value(State) = .init(.idle),
    job: Job = .none,
    /// How what it did went.
    result: ?anyerror = null,

    const State = enum(u8) { idle, queued, done };

    const Job = union(enum) {
        none,
        quit,
        frame: *const Presenter.FrameJob,
        call: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) anyerror!void },
    };

    fn start(gpa: std.mem.Allocator, p: *const Presenter) !*RenderThread {
        const t = try gpa.create(RenderThread);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .presenter = p, .ready = try .create(), .done = undefined };
        errdefer t.ready.deinit();
        t.done = try .create();
        errdefer t.done.deinit();
        t.thread = try std.Thread.spawn(.{}, run, .{t});
        return t;
    }

    /// Gives it `job` (it must be idle, or done).
    fn submit(t: *RenderThread, job: Job) void {
        t.job = job;
        t.result = null;
        t.state.store(.queued, .release);
        t.ready.signal();
    }

    fn stop(t: *RenderThread) void {
        t.submit(.quit);
        t.thread.join();
        t.ready.deinit();
        t.done.deinit();
        t.gpa.destroy(t);
    }

    fn run(t: *RenderThread) void {
        while (true) {
            while (t.state.load(.acquire) != .queued) {
                _ = sys.waitReadable(t.ready.fd(), -1);
                _ = t.ready.drain();
            }
            switch (t.job) {
                .none => {},
                .quit => return,
                .frame => |job| if (t.presenter.renderer) |r| {
                    Presenter.render(r, job) catch |e| {
                        t.result = e;
                    };
                } else {
                    t.result = error.NoRenderer;
                },
                .call => |c| c.f(c.ctx) catch |e| {
                    t.result = e;
                },
            }
            t.state.store(.done, .release);
            t.done.signal();
        }
    }
};

test "a frame is drawn where its buffer's age says, and what changed is shown" {
    const testing = std.testing;
    const w = 16;
    const h = 8;
    // A window of one buffer, last drawn the frame before.
    const Win = struct {
        width: u32 = w,
        height: u32 = h,
        pixels: [w * h]u32 = @splat(0xff000000),
        shown: [4]Viewport = undefined,
        shown_len: usize = 0,

        pub fn beginFrame(win: *@This()) !gfx.software.Image {
            return .{ .pixels = &win.pixels, .width = w, .height = h };
        }
        pub fn bufferAge(_: *const @This()) u32 {
            return 1;
        }
        pub fn showDamaged(win: *@This(), damage: ?[]const Viewport) !void {
            const d = damage.?;
            @memcpy(win.shown[0..d.len], d);
            win.shown_len = d.len;
        }
    };
    var win: Win = .{};
    var canvas = gfx.Canvas.init(testing.allocator);
    defer canvas.deinit();
    canvas.begin(w, h);
    canvas.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .rgb(0xff0000));
    var software: gfx.SoftwareRenderer = .{};
    var p: Presenter = .{ .renderer = software.renderer() };

    // All of it is red, but the buffer needs only its left half drawn.
    var f: gfx.Frame = .{ .canvases = &.{&canvas}, .segments = &.{.{ .canvas = &canvas }}, .clear = 0xff0000ff, .ages = 1 };
    f.repaints[0].add(.{ .width = w, .height = h });
    f.repaints[1].add(.{ .width = w / 2, .height = h });
    f.damage.add(.{ .width = w / 2, .height = h });
    try p.present(.from(&win), &f);
    try testing.expectEqual(@as(u32, 0xffff0000), win.pixels[0]);
    try testing.expectEqual(@as(u32, 0xffff0000), win.pixels[w / 2 - 1]);
    try testing.expectEqual(@as(u32, 0xff000000), win.pixels[w / 2]);
    try testing.expectEqual(@as(usize, 1), win.shown_len);
    try testing.expectEqual(@as(u32, w / 2), win.shown[0].width);
}
