//! Presenting frames (`gfx.Frame`s) in a window with a renderer: on the GPU
//! straight into the window's buffer (a dmabuf on Wayland, or the Metal
//! layer on macOS) if they can, or else into its buffer on the CPU; only
//! what the buffer's age says has to be drawn, and then shown (only what
//! changed). It is done here and now, on the caller's thread.
//!
//! Frames made to outlive the UI's next one (`owned_frames`, as a render
//! thread needs them) are drawn with the presenter's own copies of what
//! they carry: the glyph atlas, and the images (kept while they are drawn,
//! by `gfx.frame.Residency`).

const std = @import("std");
const gfx = @import("gfx");
const window_mod = @import("window.zig");

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

    pub fn deinit(p: *Presenter) void {
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

    /// Waits until frame `frame_no` (and those before) has been presented,
    /// so that the UI may draw in what it used again: at once, as frames
    /// are presented when they are given.
    pub fn waitRetired(_: *Presenter, _: u64) void {}

    /// Draws `frame` into the window's next buffer, and shows it.
    pub fn present(p: *Presenter, win: Window, frame: *const gfx.Frame) !void {
        try p.adopt(frame);
        const r = p.renderer orelse return error.NoRenderer;
        var uncovered_buf: [2][gfx.renderer.max_uncovered]Viewport = undefined;
        // On the GPU straight into the window's buffer (or Metal layer) if
        // they can, or else into the buffer on the CPU.
        const direct = if (p.directRenderer()) |dr| blk: {
            if (dr.hasDmabuf()) if (win.beginDmabufFrame()) |target| {
                const vps = frame.repaint(win.bufferAge());
                dr.renderDmabuf(frame.canvases, frame.segments, &target, frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments), vps) catch {
                    p.no_direct = true;
                    break :blk false;
                };
                win.finishFrame(vps);
                break :blk true;
            };
            if (dr.hasMetal()) if (win.beginMetalFrame()) |target| {
                const vps = frame.repaint(win.bufferAge());
                dr.renderMetal(frame.canvases, frame.segments, &target, frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments), vps) catch {
                    p.no_direct = true;
                    break :blk false;
                };
                win.finishFrame(vps);
                break :blk true;
            };
            break :blk false;
        } else false;
        if (!direct) {
            var img = try win.beginFrame();
            const vps = frame.repaint(win.bufferAge());
            img.clearViewports(frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments));
            try r.renderSegments(frame.canvases, frame.segments, &img, vps);
            win.finishFrame(vps);
        }
        try win.showDamaged(frame.damage.slice());
    }

    /// Draws `frame` whole into popup `id`'s next buffer, and shows it;
    /// false if the popup has no buffer to draw into yet.
    pub fn presentPopup(p: *Presenter, win: Window, id: u32, frame: *const gfx.Frame) !bool {
        try p.adopt(frame);
        const r = p.renderer orelse return error.NoRenderer;
        var img = (try win.beginPopupFrame(id)) orelse return false;
        img.clear(frame.clear);
        try r.prepare(frame.canvases);
        try r.render(frame.segments, &img, null);
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
