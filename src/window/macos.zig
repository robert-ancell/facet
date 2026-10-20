//! MacWindow: a native macOS window: AppKit's NSWindow, with the system's
//! own title bar, buttons, resizing and full screen (server-side
//! decorations), and a view of facet's in it.
//!
//! Frames are drawn on the CPU into one of three buffers in turn (so the
//! damage tracking draws only what changed, as on Wayland) and shown as
//! the contents of the view's Core Animation layer. AppKit's events become
//! facet's `InputEvent`s: macOS key codes become the Linux ones the
//! toolkit uses, and Command counts as Control (so Command and C copies).
//! Fds the toolkit waits on (image loads, wakes) are watched through the
//! main run loop, so it sleeps until there is something to do.
//!
//! Everything AppKit has is loaded when the window is opened (see
//! `objc.zig`), so facet builds for macOS without its SDK.

const std = @import("std");
const gfx = @import("gfx");
const window = @import("window.zig");
const objc = @import("objc.zig");
const sys = @import("sys.zig");
const clipboard = @import("clipboard.zig");

const Id = objc.Id;
const msg = objc.msg;
const InputEvent = window.InputEvent;

// Linux's button codes (as the toolkit has them).
const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;

// AppKit's modifier flags.
const flag_shift = 1 << 17;
const flag_control = 1 << 18;
const flag_option = 1 << 19;
const flag_command = 1 << 20;

pub const MacWindow = struct {
    gpa: std.mem.Allocator,
    win: Id,
    view: Id,
    delegate: Id,
    title_buf: []u8,
    /// The view's size in points (the toolkit's logical pixels), and how
    /// many pixels each is.
    width: u32,
    height: u32,
    scale: u32 = 1,
    closed: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    refresh_ns: u64 = std.time.ns_per_s / 60,
    /// A frame was shown less than a refresh ago (when the display shows
    /// it), so the next waits; and when it was shown.
    frame_pending: bool = false,
    presented_ns: u64 = 0,
    /// Events since the last `takeInput`, and those it gave.
    input: std.ArrayList(InputEvent) = .empty,
    taken: std.ArrayList(InputEvent) = .empty,
    modifiers: u64 = 0,
    /// The buffers frames are drawn in, in turn, and which is being drawn.
    buffers: [3]Buffer = @splat(.{}),
    back: usize = 0,
    frames: u64 = 0,
    color_space: ?*anyopaque = null,
    /// The fds watched through the run loop.
    watched: [4]?Watch = @splat(null),

    pub const platform: window.Platform = .macos;
    pub const buffer_transport: window.BufferTransport = .memory;
    pub const decorations: window.Decorations = .server;

    const Buffer = struct {
        pixels: ?*Pixels = null,
        width: u32 = 0,
        height: u32 = 0,
        /// The frame it was last shown in (0: never).
        drawn: u64 = 0,
    };

    /// A buffer's pixels, which the images shown of it share (the layer
    /// keeps its last for as long as it likes): freed when neither the
    /// buffer nor any image has them, on whichever thread lets them go
    /// last.
    const Pixels = struct {
        refs: std.atomic.Value(u32) = .init(1),
        mem: []u32,

        fn create(len: usize) !*Pixels {
            const a = std.heap.c_allocator;
            const p = try a.create(Pixels);
            p.* = .{ .mem = a.alloc(u32, len) catch |e| {
                a.destroy(p);
                return e;
            } };
            return p;
        }

        fn ref(p: *Pixels) void {
            _ = p.refs.fetchAdd(1, .monotonic);
        }

        fn unref(p: *Pixels) void {
            if (p.refs.fetchSub(1, .acq_rel) != 1) return;
            std.heap.c_allocator.free(p.mem);
            std.heap.c_allocator.destroy(p);
        }

        /// CoreGraphics is done with an image's.
        fn released(info: ?*anyopaque, _: ?*const anyopaque, _: usize) callconv(.c) void {
            const p: *Pixels = @ptrCast(@alignCast(info orelse return));
            p.unref();
        }
    };

    const Watch = struct { fd: sys.fd_t, ref: ?*anyopaque, source: ?*anyopaque };

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 960, 640 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
    };

    /// Opens a window (and, the first time, starts the app: its menu,
    /// with Quit, and its place in the Dock).
    pub fn open(gpa: std.mem.Allocator, environ: std.process.Environ, options: Options) !*MacWindow {
        _ = environ;
        try objc.load();
        const pool = objc.push();
        defer objc.pop(pool);
        const app = startApp();

        const w = try gpa.create(MacWindow);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .win = null, .view = null, .delegate = null, .title_buf = try gpa.dupe(u8, options.title), .width = options.size[0], .height = options.size[1] };
        errdefer gpa.free(w.title_buf);

        const rect: objc.Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(options.size[0]), .height = @floatFromInt(options.size[1]) } };
        // Titled, closable, minimizable and resizable: the system's frame.
        const style: u64 = 1 | 2 | 4 | 8;
        const nswin = msg(Id, objc.class("NSWindow"), "alloc", .{});
        w.win = msg(Id, nswin, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(u64, 2), objc.no });
        msg(void, w.win, "setReleasedWhenClosed:", .{objc.no});
        msg(void, w.win, "setTitle:", .{objc.nsString(options.title)});
        msg(void, w.win, "setAcceptsMouseMovedEvents:", .{objc.yes});

        // A view hosting a layer of its own, whose contents are the frames.
        w.view = msg(Id, msg(Id, viewClass(), "alloc", .{}), "initWithFrame:", .{rect});
        objc.setOwner(w.view, w);
        const layer = msg(Id, objc.class("CALayer"), "layer", .{});
        msg(void, w.view, "setLayer:", .{layer});
        msg(void, w.view, "setWantsLayer:", .{objc.yes});
        // Moves, entering and leaving, wherever the pointer is in it.
        const tracking = msg(Id, objc.class("NSTrackingArea"), "alloc", .{});
        const opts: u64 = 0x01 | 0x02 | 0x80 | 0x200; // entered/exited, moved, always, in visible rect
        const area = msg(Id, tracking, "initWithRect:options:owner:userInfo:", .{ rect, opts, w.view, @as(Id, null) });
        msg(void, w.view, "addTrackingArea:", .{area});
        msg(void, w.win, "setContentView:", .{w.view});

        w.delegate = msg(Id, delegateClass(), "new", .{});
        objc.setOwner(w.delegate, w);
        msg(void, w.win, "setDelegate:", .{w.delegate});

        if (options.min_size) |m| w.setMinSize(m[0], m[1]);
        msg(void, w.win, "center", .{});
        msg(void, w.win, "makeKeyAndOrderFront:", .{@as(Id, null)});
        msg(void, w.win, "makeFirstResponder:", .{w.view});
        if (options.maximized) msg(void, w.win, "zoom:", .{@as(Id, null)});
        msg(void, app, "activateIgnoringOtherApps:", .{objc.yes});

        w.updateScale();
        if (msg(Id, objc.class("NSScreen"), "mainScreen", .{})) |screen| {
            const fps = msg(isize, screen, "maximumFramesPerSecond", .{});
            if (fps > 0) w.refresh_ns = std.time.ns_per_s / @as(u64, @intCast(fps));
        }
        windows.append(gpa, w) catch {};
        return w;
    }

    pub fn close(w: *MacWindow) void {
        const pool = objc.push();
        defer objc.pop(pool);
        for (&w.watched) |*slot| if (slot.*) |_| w.unwatch(slot);
        msg(void, w.win, "setDelegate:", .{@as(Id, null)});
        msg(void, w.win, "close", .{});
        msg(void, w.delegate, "release", .{});
        msg(void, w.view, "release", .{});
        msg(void, w.win, "release", .{});
        for (w.buffers) |b| if (b.pixels) |px| px.unref();
        if (w.color_space) |cs| if (objc.symbol(*const fn (?*anyopaque) callconv(.c) void, "CGColorSpaceRelease")) |f| f(cs);
        w.input.deinit(w.gpa);
        w.taken.deinit(w.gpa);
        w.gpa.free(w.title_buf);
        if (std.mem.indexOfScalar(*MacWindow, windows.items, w)) |i| _ = windows.swapRemove(i);
        w.gpa.destroy(w);
    }

    pub fn getTitle(w: *const MacWindow) []const u8 {
        return w.title_buf;
    }

    pub fn size(w: *const MacWindow) [2]u32 {
        return .{ w.width, w.height };
    }

    pub fn getScale(w: *const MacWindow) u32 {
        return w.scale;
    }

    pub fn refreshNs(w: *const MacWindow) u64 {
        return w.refresh_ns;
    }

    // --- Events -------------------------------------------------------------------

    /// Handles what has come, without waiting.
    pub fn poll(w: *MacWindow) !void {
        pump(0);
        w.updatePending();
    }

    /// Waits up to `timeout_ns` for something (an event, or a watched fd
    /// readable), and handles what has come.
    pub fn wait(w: *MacWindow, timeout_ns: u64) !void {
        // Not past when the next frame can be drawn.
        var ns = timeout_ns;
        if (w.frame_pending) ns = @min(ns, w.nextPresentationNs(sys.monotonicNs()) -| sys.monotonicNs());
        // Watched fds wake it once each wait (a callback each time one is
        // readable would come again and again until it is read).
        if (cfFunctions()) |cf| for (w.watched) |slot| if (slot) |x| cf.enable(x.ref, 1);
        pump(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s);
        w.updatePending();
    }

    fn updatePending(w: *MacWindow) void {
        if (w.frame_pending and sys.monotonicNs() >= w.presented_ns + w.refresh_ns) w.frame_pending = false;
    }

    /// When a frame drawn now would be shown: at the display's next
    /// refresh after the last.
    pub fn nextPresentationNs(w: *const MacWindow, now_ns: u64) u64 {
        if (w.presented_ns == 0) return now_ns;
        if (now_ns < w.presented_ns) return w.presented_ns + w.refresh_ns;
        const periods = (now_ns - w.presented_ns) / w.refresh_ns + 1;
        return w.presented_ns + periods * w.refresh_ns;
    }

    pub fn takeInput(w: *MacWindow) []const InputEvent {
        w.taken.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(InputEvent), &w.input, &w.taken);
        return w.taken.items;
    }

    fn push(w: *MacWindow, e: InputEvent) void {
        w.input.append(w.gpa, e) catch {};
    }

    /// The view's new size, if it changed (and its scale, kept).
    pub fn applyConfigure(w: *MacWindow) !?[2]u32 {
        const pool = objc.push();
        defer objc.pop(pool);
        const bounds = objc.msgRect(w.view, "bounds");
        const nw: u32 = @intFromFloat(@max(@round(bounds.size.width), 1));
        const nh: u32 = @intFromFloat(@max(@round(bounds.size.height), 1));
        const old_scale = w.scale;
        w.updateScale();
        w.maximized = msg(objc.Bool, w.win, "isZoomed", .{}) != 0;
        w.fullscreen = msg(u64, w.win, "styleMask", .{}) & (1 << 14) != 0;
        if (nw == w.width and nh == w.height and old_scale == w.scale) return null;
        w.width = nw;
        w.height = nh;
        return .{ nw, nh };
    }

    fn updateScale(w: *MacWindow) void {
        const s = msg(objc.CGFloat, w.win, "backingScaleFactor", .{});
        w.scale = @intFromFloat(@max(@round(s), 1));
    }

    /// What the system's appearance is: dark (true) or light.
    pub fn prefersDark(_: *const MacWindow) ?bool {
        const pool = objc.push();
        defer objc.pop(pool);
        const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
        const appearance = msg(Id, app, "effectiveAppearance", .{}) orelse return null;
        const name = objc.utf8(msg(Id, appearance, "name", .{}));
        return std.mem.indexOf(u8, name, "Dark") != null;
    }

    // --- Frames -------------------------------------------------------------------

    /// The next buffer to draw a frame in, as big as the view in pixels.
    pub fn beginFrame(w: *MacWindow) !gfx.software.Image {
        w.back = (w.back + 1) % w.buffers.len;
        const b = &w.buffers[w.back];
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        if (b.pixels == null or b.width != pw or b.height != ph) {
            if (b.pixels) |px| px.unref();
            b.* = .{};
            const px = try Pixels.create(@as(usize, pw) * ph);
            @memset(px.mem, 0xff000000);
            b.* = .{ .pixels = px, .width = pw, .height = ph };
        }
        return .{ .pixels = b.pixels.?.mem, .width = pw, .height = ph };
    }

    /// How many frames ago the buffer `beginFrame` gave was last shown (0:
    /// never).
    pub fn bufferAge(w: *const MacWindow) u32 {
        const b = &w.buffers[w.back];
        if (b.drawn == 0) return 0;
        return @intCast(@min(w.frames + 1 - b.drawn, std.math.maxInt(u32)));
    }

    /// Shows the buffer drawn: the layer's contents (the whole of it; the
    /// layer is composited by the system).
    pub fn showDamaged(w: *MacWindow, _: ?[]const gfx.Viewport) !void {
        const pool = objc.push();
        defer objc.pop(pool);
        const b = &w.buffers[w.back];
        const px = b.pixels orelse return;
        const cg = cgFunctions() orelse return error.NoCoreGraphics;
        if (w.color_space == null) w.color_space = cg.colorSpace();
        // The buffer itself (not a copy): it is drawn in again only two
        // frames later, when the layer has long since shown it. The image
        // keeps its pixels (until CoreGraphics lets them go).
        px.ref();
        const provider = cg.provider(px, px.mem.ptr, px.mem.len * 4, &Pixels.released) orelse {
            px.unref();
            return error.NoCoreGraphics;
        };
        defer cg.releaseProvider(provider);
        // 0xAARRGGBB in memory, little-endian: BGRA, its alpha ignored.
        const info: u32 = (2 << 12) | 6;
        const image = cg.image(b.width, b.height, 8, 32, @as(usize, b.width) * 4, w.color_space, info, provider, null, false, 0);
        defer cg.releaseImage(image);
        const transaction = objc.class("CATransaction");
        msg(void, transaction, "begin", .{});
        msg(void, transaction, "setDisableActions:", .{objc.yes});
        msg(void, msg(Id, w.view, "layer", .{}), "setContents:", .{image});
        msg(void, transaction, "commit", .{});
        w.frames += 1;
        b.drawn = w.frames;
        w.presented_ns = w.nextPresentationNs(sys.monotonicNs());
        w.frame_pending = true;
    }

    // --- The window ------------------------------------------------------------------

    pub fn setMinSize(w: *MacWindow, width: u32, height: u32) void {
        msg(void, w.win, "setContentMinSize:", .{objc.Size{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
    }

    pub fn setMaximized(w: *MacWindow, on: bool) void {
        if ((msg(objc.Bool, w.win, "isZoomed", .{}) != 0) != on) msg(void, w.win, "zoom:", .{@as(Id, null)});
    }

    pub fn setMinimized(w: *MacWindow) void {
        msg(void, w.win, "miniaturize:", .{@as(Id, null)});
    }

    pub fn setFullscreen(w: *MacWindow, on: bool) void {
        if (w.fullscreen != on) msg(void, w.win, "toggleFullScreen:", .{@as(Id, null)});
    }

    pub fn setCursor(_: *MacWindow, cursor: window.Cursor) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const name: [*:0]const u8 = switch (cursor) {
            .pointer => "pointingHandCursor",
            .text => "IBeamCursor",
            .grab => "openHandCursor",
            .grabbing, .move => "closedHandCursor",
            .crosshair => "crosshairCursor",
            .not_allowed => "operationNotAllowedCursor",
            .ew_resize => "resizeLeftRightCursor",
            .ns_resize => "resizeUpDownCursor",
            else => "arrowCursor",
        };
        msg(void, msg(Id, objc.class("NSCursor"), name, .{}), "set", .{});
    }

    pub fn copy(_: *MacWindow, text: []const u8) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
        _ = msg(isize, pb, "clearContents", .{});
        _ = msg(objc.Bool, pb, "setString:forType:", .{ objc.nsString(text), objc.constant("NSPasteboardTypeString") });
    }

    pub fn paste(_: *MacWindow, sink: clipboard.Sink) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const str = msg(Id, pb, "stringForType:", .{objc.constant("NSPasteboardTypeString")});
        sink.f(sink.ctx, if (str == null) null else objc.utf8(str));
    }

    // --- Watching fds -------------------------------------------------------------------

    /// Wakes `wait` when `fd` is readable (or stops, if not `on`).
    pub fn watchFd(w: *MacWindow, fd: sys.fd_t, on: bool) void {
        for (&w.watched) |*slot| if (slot.*) |x| if (x.fd == fd) {
            if (!on) w.unwatch(slot);
            return;
        };
        if (!on) return;
        const cf = cfFunctions() orelse return;
        for (&w.watched) |*slot| if (slot.* == null) {
            var ctx: CFContext = .{ .info = w };
            const ref = cf.create(null, fd, 0, fdReadable, &ctx) orelse return;
            cf.enable(ref, 1);
            const source = cf.source(null, ref, 0);
            cf.addSource(cf.mainLoop(), source, objc.constant("kCFRunLoopCommonModes"));
            slot.* = .{ .fd = fd, .ref = ref, .source = source };
            return;
        };
    }

    fn unwatch(_: *MacWindow, slot: *?Watch) void {
        const x = slot.* orelse return;
        if (cfFunctions()) |cf| {
            cf.invalidateSource(x.source);
            cf.invalidate(x.ref);
            cf.release(x.source);
            cf.release(x.ref);
        }
        slot.* = null;
    }

    // --- AppKit's calls --------------------------------------------------------------

    fn ofView(view: Id) ?*MacWindow {
        return objc.owner(MacWindow, view);
    }

    /// Where an event happened, in the view (top left at 0, 0).
    fn locate(w: *const MacWindow, event: Id) [2]f32 {
        const in_window = msg(objc.Point, event, "locationInWindow", .{});
        const p = msg(objc.Point, w.view, "convertPoint:fromView:", .{ in_window, @as(Id, null) });
        return .{ @floatCast(p.x), @floatCast(p.y) };
    }

    fn mouse(view: Id, event: Id, code: u32, pressed: bool) void {
        const w = ofView(view) orelse return;
        const pos = w.locate(event);
        w.push(.{ .motion = pos });
        w.push(.{ .button = .{ .pos = pos, .code = code, .pressed = pressed } });
    }

    fn key(view: Id, event: Id, pressed: bool) void {
        const w = ofView(view) orelse return;
        const flags = msg(u64, event, "modifierFlags", .{});
        w.modifiers = flags;
        // A key with no Linux code of its own still types what it does.
        const code = linuxKey(msg(u16, event, "keyCode", .{})) orelse 0;
        // What it types (none for controls and function keys).
        var char: ?u21 = null;
        if (pressed) {
            const text = objc.utf8(msg(Id, event, "characters", .{}));
            if (text.len > 0) if (std.unicode.utf8Decode(text[0..(std.unicode.utf8ByteSequenceLength(text[0]) catch 1)])) |ch| {
                if (ch >= 0x20 and ch != 0x7f and !(ch >= 0xf700 and ch <= 0xf8ff)) char = ch;
            } else |_| {};
        }
        const ctrl = flags & (flag_control | flag_command) != 0;
        if (code == 0 and (char == null or ctrl)) return;
        w.push(.{ .key = .{ .code = code, .pressed = pressed, .char = if (ctrl) null else char, .shift = flags & flag_shift != 0, .ctrl = ctrl } });
    }

    const view_methods = struct {
        fn yesFn(_: Id, _: objc.Sel) callconv(.c) objc.Bool {
            return objc.yes;
        }
        fn mouseDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, btn_left, true);
        }
        fn mouseUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, btn_left, false);
        }
        fn rightMouseDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, btn_right, true);
        }
        fn rightMouseUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, btn_right, false);
        }
        fn otherMouseDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, btn_middle, true);
        }
        fn otherMouseUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, btn_middle, false);
        }
        fn mouseMoved(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            w.push(.{ .motion = w.locate(e) });
        }
        fn mouseExited(v: Id, _: objc.Sel, _: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            w.push(.leave);
        }
        fn scrollWheel(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            // A trackpad's in points; a wheel's in lines (about ten each).
            const precise = msg(objc.Bool, e, "hasPreciseScrollingDeltas", .{}) != 0;
            const k: f64 = if (precise) 1 else 10;
            const dx = msg(objc.CGFloat, e, "scrollingDeltaX", .{});
            const dy = msg(objc.CGFloat, e, "scrollingDeltaY", .{});
            w.push(.{ .scroll = .{ .pos = w.locate(e), .dx = @floatCast(-dx * k), .dy = @floatCast(-dy * k) } });
        }
        fn keyDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            key(v, e, true);
        }
        fn keyUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            key(v, e, false);
        }
        fn flagsChanged(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            w.modifiers = msg(u64, e, "modifierFlags", .{});
        }
        fn nothing(_: Id, _: objc.Sel) callconv(.c) void {}
    };

    const delegate_methods = struct {
        fn windowShouldClose(d: Id, _: objc.Sel, _: Id) callconv(.c) objc.Bool {
            // The app closes it, when it has seen that it was asked to.
            if (objc.owner(MacWindow, d)) |w| w.closed = true;
            return objc.no;
        }
        fn changed(d: Id, _: objc.Sel, _: Id) callconv(.c) void {
            // A size or scale to apply: woken to.
            _ = d;
            postWake();
        }
    };

    fn viewClass() objc.Class {
        const m = view_methods;
        const b = if (@import("builtin").cpu.arch == .aarch64) "B@:" else "c@:";
        return objc.makeClass("FacetView", "NSView", &.{
            .{ .sel = "acceptsFirstResponder", .imp = &m.yesFn, .types = b },
            .{ .sel = "isFlipped", .imp = &m.yesFn, .types = b },
            .{ .sel = "acceptsFirstMouse:", .imp = &m.yesFn, .types = b },
            .{ .sel = "mouseDown:", .imp = &m.mouseDown, .types = "v@:@" },
            .{ .sel = "mouseUp:", .imp = &m.mouseUp, .types = "v@:@" },
            .{ .sel = "rightMouseDown:", .imp = &m.rightMouseDown, .types = "v@:@" },
            .{ .sel = "rightMouseUp:", .imp = &m.rightMouseUp, .types = "v@:@" },
            .{ .sel = "otherMouseDown:", .imp = &m.otherMouseDown, .types = "v@:@" },
            .{ .sel = "otherMouseUp:", .imp = &m.otherMouseUp, .types = "v@:@" },
            .{ .sel = "mouseMoved:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "mouseDragged:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "rightMouseDragged:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "otherMouseDragged:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "mouseExited:", .imp = &m.mouseExited, .types = "v@:@" },
            .{ .sel = "scrollWheel:", .imp = &m.scrollWheel, .types = "v@:@" },
            .{ .sel = "keyDown:", .imp = &m.keyDown, .types = "v@:@" },
            .{ .sel = "keyUp:", .imp = &m.keyUp, .types = "v@:@" },
            .{ .sel = "flagsChanged:", .imp = &m.flagsChanged, .types = "v@:@" },
        });
    }

    fn delegateClass() objc.Class {
        const m = delegate_methods;
        const b = if (@import("builtin").cpu.arch == .aarch64) "B@:@" else "c@:@";
        return objc.makeClass("FacetWindowDelegate", "NSObject", &.{
            .{ .sel = "windowShouldClose:", .imp = &m.windowShouldClose, .types = b },
            .{ .sel = "windowDidResize:", .imp = &m.changed, .types = "v@:@" },
            .{ .sel = "windowDidChangeBackingProperties:", .imp = &m.changed, .types = "v@:@" },
            .{ .sel = "windowDidEnterFullScreen:", .imp = &m.changed, .types = "v@:@" },
            .{ .sel = "windowDidExitFullScreen:", .imp = &m.changed, .types = "v@:@" },
        });
    }
};

/// The windows open (Quit closes them all).
var windows: std.ArrayList(*MacWindow) = .empty;
var app_started = false;

/// The shared application, started once: in the Dock, with a menu (the
/// app's, with Quit), and Quit asking the windows to close rather than
/// ending the process.
fn startApp() Id {
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    if (app_started) return app;
    app_started = true;
    _ = msg(objc.Bool, app, "setActivationPolicy:", .{@as(isize, 0)});
    const delegate = msg(Id, objc.makeClass("FacetAppDelegate", "NSObject", &.{
        .{ .sel = "applicationShouldTerminate:", .imp = &shouldTerminate, .types = "Q@:@" },
    }), "new", .{});
    msg(void, app, "setDelegate:", .{delegate});

    const bar = objc.new(objc.class("NSMenu"));
    const app_item = objc.new(objc.class("NSMenuItem"));
    msg(void, bar, "addItem:", .{app_item});
    const app_menu = objc.new(objc.class("NSMenu"));
    const quit = msg(Id, msg(Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ objc.nsString("Quit"), objc.sel("terminate:"), objc.nsString("q") });
    msg(void, app_menu, "addItem:", .{quit});
    msg(void, app_item, "setSubmenu:", .{app_menu});
    msg(void, app, "setMainMenu:", .{bar});
    msg(void, app, "finishLaunching", .{});
    return app;
}

fn shouldTerminate(_: Id, _: objc.Sel, _: Id) callconv(.c) u64 {
    for (windows.items) |w| w.closed = true;
    postWake();
    // NSTerminateCancel: the app ends when it sees its windows closed.
    return 0;
}

/// Handles AppKit's events: those that have come, or the first to come
/// within `seconds` (and those after it).
fn pump(seconds: f64) void {
    const pool = objc.push();
    defer objc.pop(pool);
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const mode = objc.constant("NSDefaultRunLoopMode");
    var wait_for = seconds;
    while (true) {
        const until = msg(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{wait_for});
        const event = msg(Id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(u64, std.math.maxInt(u64)), until, mode, objc.yes }) orelse break;
        // Our own wakes are only to stop waiting.
        if (msg(u64, event, "type", .{}) != 15) msg(void, app, "sendEvent:", .{event});
        wait_for = 0;
    }
    msg(void, app, "updateWindows", .{});
}

/// Stops `pump` waiting (posting an event of the app's own, which it
/// passes over).
fn postWake() void {
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const event = msg(Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
        @as(u64, 15), objc.Point{ .x = 0, .y = 0 }, @as(u64, 0), @as(f64, 0), @as(isize, 0), @as(Id, null), @as(i16, 0), @as(isize, 0), @as(isize, 0),
    });
    msg(void, app, "postEvent:atStart:", .{ event, objc.yes });
}

// --- CoreFoundation and CoreGraphics ---------------------------------------------------

const CFContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    describe: ?*const anyopaque = null,
};

const CF = struct {
    create: *const fn (?*anyopaque, sys.fd_t, u8, *const fn (?*anyopaque, u64, ?*anyopaque) callconv(.c) void, *const CFContext) callconv(.c) ?*anyopaque,
    enable: *const fn (?*anyopaque, u64) callconv(.c) void,
    source: *const fn (?*anyopaque, ?*anyopaque, isize) callconv(.c) ?*anyopaque,
    mainLoop: *const fn () callconv(.c) ?*anyopaque,
    addSource: *const fn (?*anyopaque, ?*anyopaque, Id) callconv(.c) void,
    invalidate: *const fn (?*anyopaque) callconv(.c) void,
    invalidateSource: *const fn (?*anyopaque) callconv(.c) void,
    release: *const fn (?*anyopaque) callconv(.c) void,
};

fn cfFunctions() ?CF {
    return .{
        .create = objc.symbol(@FieldType(CF, "create"), "CFFileDescriptorCreate") orelse return null,
        .enable = objc.symbol(@FieldType(CF, "enable"), "CFFileDescriptorEnableCallBacks") orelse return null,
        .source = objc.symbol(@FieldType(CF, "source"), "CFFileDescriptorCreateRunLoopSource") orelse return null,
        .mainLoop = objc.symbol(@FieldType(CF, "mainLoop"), "CFRunLoopGetMain") orelse return null,
        .addSource = objc.symbol(@FieldType(CF, "addSource"), "CFRunLoopAddSource") orelse return null,
        .invalidate = objc.symbol(@FieldType(CF, "invalidate"), "CFFileDescriptorInvalidate") orelse return null,
        .invalidateSource = objc.symbol(@FieldType(CF, "invalidateSource"), "CFRunLoopSourceInvalidate") orelse return null,
        .release = objc.symbol(@FieldType(CF, "release"), "CFRelease") orelse return null,
    };
}

/// A watched fd is readable: `pump` stops waiting (it is watched again
/// at the next `wait`).
fn fdReadable(_: ?*anyopaque, _: u64, _: ?*anyopaque) callconv(.c) void {
    postWake();
}

const CG = struct {
    colorSpace: *const fn () callconv(.c) ?*anyopaque,
    provider: *const fn (?*anyopaque, *const anyopaque, usize, ?*const fn (?*anyopaque, ?*const anyopaque, usize) callconv(.c) void) callconv(.c) ?*anyopaque,
    image: *const fn (usize, usize, usize, usize, usize, ?*anyopaque, u32, ?*anyopaque, ?*const anyopaque, bool, i32) callconv(.c) Id,
    releaseProvider: *const fn (?*anyopaque) callconv(.c) void,
    releaseImage: *const fn (Id) callconv(.c) void,
};

fn cgFunctions() ?CG {
    return .{
        .colorSpace = objc.symbol(@FieldType(CG, "colorSpace"), "CGColorSpaceCreateDeviceRGB") orelse return null,
        .provider = objc.symbol(@FieldType(CG, "provider"), "CGDataProviderCreateWithData") orelse return null,
        .image = objc.symbol(@FieldType(CG, "image"), "CGImageCreate") orelse return null,
        .releaseProvider = objc.symbol(@FieldType(CG, "releaseProvider"), "CGDataProviderRelease") orelse return null,
        .releaseImage = objc.symbol(@FieldType(CG, "releaseImage"), "CGImageRelease") orelse return null,
    };
}

// --- Keys ------------------------------------------------------------------------------

/// The Linux key code (as the toolkit has them) of a macOS one.
pub fn linuxKey(mac: u16) ?u32 {
    return switch (mac) {
        0 => 30, // A
        1 => 31, // S
        2 => 32, // D
        3 => 33, // F
        4 => 35, // H
        5 => 34, // G
        6 => 44, // Z
        7 => 45, // X
        8 => 46, // C
        9 => 47, // V
        11 => 48, // B
        12 => 16, // Q
        13 => 17, // W
        14 => 18, // E
        15 => 19, // R
        16 => 21, // Y
        17 => 20, // T
        18 => 2, // 1
        19 => 3, // 2
        20 => 4, // 3
        21 => 5, // 4
        22 => 7, // 6
        23 => 6, // 5
        24 => 13, // =
        25 => 10, // 9
        26 => 8, // 7
        27 => 12, // -
        28 => 9, // 8
        29 => 11, // 0
        30 => 27, // ]
        31 => 24, // O
        32 => 22, // U
        33 => 26, // [
        34 => 23, // I
        35 => 25, // P
        36 => 28, // Return
        37 => 38, // L
        38 => 36, // J
        39 => 40, // '
        40 => 37, // K
        41 => 39, // ;
        42 => 43, // backslash
        43 => 51, // ,
        44 => 53, // /
        45 => 49, // N
        46 => 50, // M
        47 => 52, // .
        48 => 15, // Tab
        49 => 57, // Space
        50 => 41, // `
        51 => 14, // Delete (backspace)
        10 => 86, // the ISO key by the left Shift
        53 => 1, // Escape
        65 => 83, // keypad .
        67 => 55, // keypad *
        69 => 78, // keypad +
        71 => 69, // keypad Clear (Num Lock)
        75 => 98, // keypad /
        76 => 96, // keypad Enter
        78 => 74, // keypad -
        81 => 117, // keypad =
        82 => 82, // keypad 0
        83 => 79, // keypad 1
        84 => 80, // keypad 2
        85 => 81, // keypad 3
        86 => 75, // keypad 4
        87 => 76, // keypad 5
        88 => 77, // keypad 6
        89 => 71, // keypad 7
        91 => 72, // keypad 8
        92 => 73, // keypad 9
        96 => 63, // F5
        97 => 64, // F6
        98 => 65, // F7
        99 => 61, // F3
        100 => 66, // F8
        101 => 67, // F9
        103 => 87, // F11
        109 => 68, // F10
        111 => 88, // F12
        114 => 110, // Help (Insert)
        115 => 102, // Home
        116 => 104, // Page Up
        117 => 111, // forward Delete
        118 => 62, // F4
        119 => 107, // End
        120 => 60, // F2
        121 => 109, // Page Down
        122 => 59, // F1
        123 => 105, // Left
        124 => 106, // Right
        125 => 108, // Down
        126 => 103, // Up
        else => null,
    };
}

test "macOS keys become the Linux ones the toolkit has" {
    const keymap = struct {
        const escape = 1;
        const tab = 15;
        const enter = 28;
        const left = 105;
    };
    try std.testing.expectEqual(@as(?u32, keymap.escape), linuxKey(53));
    try std.testing.expectEqual(@as(?u32, keymap.tab), linuxKey(48));
    try std.testing.expectEqual(@as(?u32, keymap.enter), linuxKey(36));
    try std.testing.expectEqual(@as(?u32, keymap.left), linuxKey(123));
    try std.testing.expectEqual(@as(?u32, 46), linuxKey(8)); // C, for Command and C
    try std.testing.expect(linuxKey(200) == null);
}
