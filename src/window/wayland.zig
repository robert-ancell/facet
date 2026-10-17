//! Wayland client window (`xdg_toplevel` + `wl_shm` shared-memory buffers)
//! with pointer, touch, keyboard (including key repeat), cursor shapes
//! (`wp_cursor_shape_v1`), clipboard and drag-and-drop (`wl_data_device`),
//! text input (`zwp_text_input_v3`), pointer lock (`zwp_pointer_constraints_v1`),
//! and presentation feedback (`wp_presentation`).

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");
const gfx = @import("gfx");
const window_mod = @import("window.zig");
const clipboard_mod = @import("clipboard.zig");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

pub const Clipboard = clipboard_mod.Clipboard;
pub const DroppedData = clipboard_mod.DroppedData;
pub const InputEvent = window_mod.InputEvent;
pub const TextInputState = window_mod.TextInputState;
pub const Keyboard = window_mod.Keyboard;
pub const nowNs = clipboard_mod.nowNs;

const default_size = [2]u32{ 1280, 720 };

pub const resize_border = 6;
pub const resize_corner = 20;

pub const edge_top = 1;
pub const edge_bottom = 2;
pub const edge_left = 4;
pub const edge_right = 8;

const max_buffers = 2;

const Buffer = struct {
    drawn: u64 = 0,
    fd: linux.fd_t,
    pixels: []align(std.heap.page_size_min) u8,
    pool: client.Proxy,
    proxy: client.Proxy,
    width: u32,
    height: u32,
    busy: bool = false,

    pub fn image(b: *Buffer) gfx.software.Image {
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        return .{
            .pixels = words[0 .. @as(usize, b.width) * @as(usize, b.height)],
            .stride = b.width,
            .width = b.width,
            .height = b.height,
        };
    }
};

pub const WaylandWindow = struct {
    gpa: std.mem.Allocator,
    conn: *client.Display,
    globals: client.Globals = .{},
    compositor: client.Proxy = undefined,
    wm_base: client.Proxy = undefined,
    shm: client.Proxy = undefined,
    surface: client.Proxy = undefined,
    xdg_surface: client.Proxy = undefined,
    toplevel: client.Proxy = undefined,

    width: u32 = default_size[0],
    height: u32 = default_size[1],
    scale: u32 = 1,
    next_size: [2]i32 = .{ 0, 0 },
    pending_serial: ?u32 = null,
    closed: bool = false,
    suspended: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    press_serial: u32 = 0,
    buttons_down: u32 = 0,
    enter_serial: u32 = 0,

    cursor_shape_manager: ?client.Proxy = null,
    cursor_device: ?client.Proxy = null,
    cursor_shape: ?u32 = null,
    app_cursor: u32 = p.wp_cursor_shape_device_v1.shape.default,

    buffers: [max_buffers]?Buffer = @splat(null),
    back: ?usize = null,
    frame_pending: bool = false,
    frames: u64 = 0,

    presentation: ?client.Proxy = null,
    presentation_clock_id: u32 = 1,
    presented_ns: u64 = 0,
    refresh_ns: u64 = 0,
    presentation_seq: u64 = 0,
    presentation_flags: u32 = 0,
    presented_frames: u64 = 0,
    discarded_frames: u64 = 0,

    seat: ?client.Proxy = null,
    touch: ?client.Proxy = null,
    text_input_manager: ?client.Proxy = null,
    text_input: ?client.Proxy = null,
    text_input_entered: bool = false,
    text_input_enabled: bool = false,
    text_input_has_preedit: bool = false,
    text_input_serial: u32 = 0,
    text_input_state: TextInputState = .{},
    text_input_surrounding_buf: [256]u8 = undefined,
    text_input_pending_preedit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,
    } = null,
    text_input_pending_commit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
    } = null,
    text_input_pending_delete: ?struct {
        before_length: u32,
        after_length: u32,
    } = null,

    pointer_constraints: ?client.Proxy = null,
    relative_pointer_manager: ?client.Proxy = null,
    relative_pointer: ?client.Proxy = null,
    locked_pointer: ?client.Proxy = null,
    pointer_locked: bool = false,

    clipboard: Clipboard,
    layout: Keyboard = .us,
    wake_fd: ?linux.fd_t = null,
    wake_fds: [4]?linux.fd_t = @splat(null),
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,

    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    repeat: ?struct { code: u32, next_ns: u64 } = null,
    keys_down: std.StaticBitSet(256) = .initEmpty(),
    pointer_pos: [2]f32 = .{ 0, 0 },
    input: [64]InputEvent = undefined,
    input_len: usize = 0,

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = default_size,
        min_size: ?[2]u32 = null,
        maximized: bool = false,
    };

    /// Connects to the compositor named in `environ` (`WAYLAND_DISPLAY`
    /// under `XDG_RUNTIME_DIR`) and opens a window.
    pub fn open(gpa: std.mem.Allocator, environ: std.process.Environ, options: Options) !*WaylandWindow {
        var path_buf: [256]u8 = undefined;
        const path = try client.environSocketPath(&path_buf, environ);
        return openPath(gpa, path, options);
    }

    /// Connects to the compositor listening on `path` and opens a window.
    pub fn openPath(gpa: std.mem.Allocator, path: []const u8, options: Options) !*WaylandWindow {
        const conn = try client.Display.connect(gpa, path);
        errdefer conn.disconnect();
        return openOn(gpa, conn, options);
    }

    /// Opens a window on an existing connection, which the window then owns.
    /// Waits for the first configure.
    pub fn openOn(gpa: std.mem.Allocator, conn: *client.Display, options: Options) !*WaylandWindow {
        const w = try gpa.create(WaylandWindow);
        errdefer gpa.destroy(w);
        w.* = .{
            .gpa = gpa,
            .conn = conn,
            .clipboard = .{ .gpa = gpa },
            .width = options.size[0],
            .height = options.size[1],
            .maximized = options.maximized,
        };
        w.clipboard.drag_callbacks = .{
            .ctx = w,
            .enter = onDragEnter,
            .motion = onDragMotion,
            .leave = onDragLeave,
            .drop = onDragDrop,
        };

        const registry = try w.globals.fetch(conn);
        w.compositor = (try w.globals.bind(registry, p.wl_compositor.name, 6, null)) orelse return error.NoCompositor;
        w.wm_base = (try w.globals.bind(registry, p.xdg_wm_base.name, 6, .{ .ptr = w, .handler = wmBaseEvent })) orelse return error.NoXdgShell;
        w.shm = (try w.globals.bind(registry, p.wl_shm.name, 1, null)) orelse return error.NoShm;

        w.cursor_shape_manager = try w.globals.bind(registry, p.wp_cursor_shape_manager_v1.name, 1, null);
        w.presentation = try w.globals.bind(registry, p.wp_presentation.name, 1, .{ .ptr = w, .handler = presentationEvent });
        w.pointer_constraints = try w.globals.bind(registry, p.zwp_pointer_constraints_v1.name, 1, null);
        w.relative_pointer_manager = try w.globals.bind(registry, p.zwp_relative_pointer_manager_v1.name, 1, null);
        w.seat = try w.globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = w, .handler = seatEvent });

        try w.clipboard.attach(conn, try w.globals.bind(registry, p.wl_data_device_manager.name, 3, null), w.seat);

        w.text_input_manager = try w.globals.bind(registry, p.zwp_text_input_manager_v3.name, 1, null);
        if (w.text_input_manager) |mgr| if (w.seat) |seat| {
            const ti = try conn.newObject(.{ .ptr = w, .handler = textInputEvent });
            var m = try mgr.request(p.zwp_text_input_manager_v3.request.get_text_input);
            m.uint(ti.id).uint(seat.id).end();
            w.text_input = ti;
        };

        w.surface = try conn.newObject(.{ .ptr = w, .handler = surfaceEvent });
        var m = try w.compositor.request(p.wl_compositor.request.create_surface);
        m.uint(w.surface.id).end();
        w.xdg_surface = try conn.newObject(.{ .ptr = w, .handler = xdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(w.xdg_surface.id).uint(w.surface.id).end();
        w.toplevel = try conn.newObject(.{ .ptr = w, .handler = toplevelEvent });
        m = try w.xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(w.toplevel.id).end();
        m = try w.toplevel.request(p.xdg_toplevel.request.set_title);
        m.string(options.title).end();
        if (options.app_id) |app_id| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
            m.string(app_id).end();
        }
        if (options.min_size) |min_size| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_min_size);
            m.int(@intCast(min_size[0])).int(@intCast(min_size[1])).end();
        }
        if (options.maximized) {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_maximized);
            m.end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        _ = try w.applyConfigure();
        return w;
    }

    pub fn close(w: *WaylandWindow) void {
        w.clipboard.deinit();
        for (&w.buffers) |*slot| if (slot.*) |*b| w.freeBuffer(b, slot);
        w.conn.flush() catch {};
        w.conn.disconnect();
        w.gpa.destroy(w);
    }

    pub fn interface(w: *WaylandWindow) window_mod.Window {
        return window_mod.Window.of(w);
    }

    pub fn setAppId(w: *WaylandWindow, app_id: []const u8) !void {
        var m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
        m.string(app_id).end();
    }

    pub fn poll(w: *WaylandWindow) !void {
        _ = try w.conn.dispatchPending();
        w.clipboard.service();
        w.serviceRepeat(nowNs());
    }

    pub fn setFullscreen(w: *WaylandWindow, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_fullscreen else p.xdg_toplevel.request.unset_fullscreen) catch return;
        if (on) _ = m.uint(0);
        m.end();
        w.conn.flush() catch {};
    }

    pub fn lockPointer(w: *WaylandWindow) bool {
        if (w.locked_pointer != null) return true;
        const constraints = w.pointer_constraints orelse return false;
        const pointer = w.pointer orelse return false;
        if (w.relative_pointer == null) return false;
        const lock = w.conn.newObject(.{ .ptr = w, .handler = lockEvent }) catch return false;
        var m = constraints.request(p.zwp_pointer_constraints_v1.request.lock_pointer) catch return false;
        m.uint(lock.id).uint(w.surface.id).uint(pointer.id).uint(0).uint(p.zwp_pointer_constraints_v1.lifetime.persistent).end();
        w.conn.flush() catch {};
        w.locked_pointer = lock;
        return true;
    }

    pub fn unlockPointer(w: *WaylandWindow) void {
        const lock = w.locked_pointer orelse return;
        if (lock.request(p.zwp_locked_pointer_v1.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(lock.id);
        w.locked_pointer = null;
        if (w.pointer_locked) {
            w.pointer_locked = false;
            w.pushInput(.{ .pointer_locked = false });
        }
        w.conn.flush() catch {};
    }

    fn lockEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const locked = opcode == p.zwp_locked_pointer_v1.event.locked;
        if (locked == w.pointer_locked) return;
        w.pointer_locked = locked;
        w.pushInput(.{ .pointer_locked = locked });
    }

    fn relativeEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_relative_pointer_v1.event.relative_motion) return;
        _ = r.uint() catch return;
        _ = r.uint() catch return;
        const dx: f32 = @floatCast(r.fixed() catch return);
        const dy: f32 = @floatCast(r.fixed() catch return);
        w.pushInput(.{ .relative_motion = .{ dx, dy } });
    }

    pub fn setMaximized(w: *WaylandWindow, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_maximized else p.xdg_toplevel.request.unset_maximized) catch return;
        m.end();
        w.conn.flush() catch {};
    }

    pub fn setMinSize(w: *WaylandWindow, width: u32, height: u32) void {
        var m = w.toplevel.request(p.xdg_toplevel.request.set_min_size) catch return;
        m.int(@intCast(width)).int(@intCast(height)).end();
        w.conn.flush() catch {};
    }

    pub fn edgesAt(w: *const WaylandWindow, pos: [2]f32) u32 {
        if (w.maximized or w.fullscreen) return 0;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const x = pos[0];
        const y = pos[1];
        if (x < 0 or y < 0 or x >= width or y >= height) return 0;
        var edges: u32 = 0;
        if (x < resize_border) edges |= edge_left else if (x >= width - resize_border) edges |= edge_right;
        if (y < resize_border) edges |= edge_top else if (y >= height - resize_border) edges |= edge_bottom;
        if (edges & (edge_left | edge_right) != 0 and edges & (edge_top | edge_bottom) == 0) {
            if (y < resize_corner) edges |= edge_top else if (y >= height - resize_corner) edges |= edge_bottom;
        }
        if (edges & (edge_top | edge_bottom) != 0 and edges & (edge_left | edge_right) == 0) {
            if (x < resize_corner) edges |= edge_left else if (x >= width - resize_corner) edges |= edge_right;
        }
        return edges;
    }

    pub fn setCursor(w: *WaylandWindow, shape: u32) void {
        if (w.app_cursor == shape) return;
        w.app_cursor = shape;
        w.updateCursor();
    }

    fn updateCursor(w: *WaylandWindow) void {
        const edges = if (w.buttons_down == 0) w.edgesAt(w.pointer_pos) else 0;
        const sh = p.wp_cursor_shape_device_v1.shape;
        const vertical = edges & (edge_top | edge_bottom);
        const horizontal = edges & (edge_left | edge_right);
        const shape: u32 = if (vertical != 0 and horizontal != 0)
            (if ((vertical == edge_top) == (horizontal == edge_left)) sh.nwse_resize else sh.nesw_resize)
        else if (horizontal != 0) sh.ew_resize else if (vertical != 0) sh.ns_resize else w.app_cursor;
        if (w.cursor_shape == shape) return;
        const device = w.cursor_device orelse return;
        var m = device.request(p.wp_cursor_shape_device_v1.request.set_shape) catch return;
        m.uint(w.enter_serial).uint(shape).end();
        w.cursor_shape = shape;
    }

    pub fn startDrag(w: *WaylandWindow, mime_type: []const u8, bytes: []const u8, actions: u32) bool {
        return w.clipboard.startDrag(w.surface, null, mime_type, bytes, actions);
    }

    pub fn takeDrop(w: *WaylandWindow) ?DroppedData {
        return w.clipboard.takeDrop();
    }

    pub fn nextPresentationNs(w: *const WaylandWindow, now_ns: u64) u64 {
        if (w.presented_ns == 0 or w.refresh_ns == 0) return now_ns;
        if (now_ns < w.presented_ns) return w.presented_ns + w.refresh_ns;
        const elapsed = now_ns - w.presented_ns;
        const periods = elapsed / w.refresh_ns + 1;
        return w.presented_ns + periods * w.refresh_ns;
    }

    pub fn setTextInput(w: *WaylandWindow, state: ?TextInputState) void {
        const ti = w.text_input orelse return;
        if (!w.text_input_entered) {
            if (state) |s| {
                w.saveTextInputState(s);
                w.text_input_enabled = true;
            } else {
                w.text_input_enabled = false;
            }
            return;
        }
        if (state) |s| {
            if (w.text_input_enabled and w.text_input_state.eql(s)) return;
            const enabling = !w.text_input_enabled;
            w.saveTextInputState(s);
            w.text_input_enabled = true;
            w.sendTextInputState(ti, enabling);
        } else {
            if (!w.text_input_enabled) return;
            w.text_input_enabled = false;
            var m = ti.request(p.zwp_text_input_v3.request.disable) catch return;
            m.end();
            m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
            m.end();
            w.text_input_serial +%= 1;
            w.conn.flush() catch {};
        }
    }

    fn saveTextInputState(w: *WaylandWindow, s: TextInputState) void {
        const n = @min(s.surrounding_text.len, w.text_input_surrounding_buf.len);
        @memcpy(w.text_input_surrounding_buf[0..n], s.surrounding_text[0..n]);
        w.text_input_state = s;
        w.text_input_state.surrounding_text = w.text_input_surrounding_buf[0..n];
        w.text_input_state.cursor = @min(s.cursor, @as(u32, @intCast(n)));
        w.text_input_state.anchor = @min(s.anchor, @as(u32, @intCast(n)));
    }

    fn sendTextInputState(w: *WaylandWindow, ti: client.Proxy, send_enable: bool) void {
        const s = w.text_input_state;
        if (send_enable) {
            var m = ti.request(p.zwp_text_input_v3.request.enable) catch return;
            m.end();
        }
        var m = ti.request(p.zwp_text_input_v3.request.set_surrounding_text) catch return;
        m.string(s.surrounding_text).uint(s.cursor).uint(s.anchor).end();
        m = ti.request(p.zwp_text_input_v3.request.set_text_change_cause) catch return;
        m.uint(s.change_cause).end();
        m = ti.request(p.zwp_text_input_v3.request.set_content_type) catch return;
        m.uint(s.content_hint).uint(s.content_purpose).end();
        m = ti.request(p.zwp_text_input_v3.request.set_cursor_rectangle) catch return;
        m.int(s.cursor_rect[0]).int(s.cursor_rect[1]).int(s.cursor_rect[2]).int(s.cursor_rect[3]).end();
        m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
        m.end();
        w.text_input_serial +%= 1;
        w.conn.flush() catch {};
    }

    pub fn startMove(w: *WaylandWindow) void {
        if (w.press_serial == 0) return;
        const seat = w.seat orelse return;
        var m = w.toplevel.request(p.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(w.press_serial).end();
        w.conn.flush() catch {};
    }

    pub fn wait(w: *WaylandWindow, timeout_ns: u64) !void {
        const now = nowNs();
        const caller_ms: u64 = std.math.divCeil(u64, timeout_ns, std.time.ns_per_ms) catch 0;
        const timeout_ms = @min(caller_ms, w.repeatTimeoutMs(now) orelse caller_ms);
        const paste_fd = w.clipboard.pasteFd();
        const has_wake_fds = for (w.wake_fds) |fd| {
            if (fd != null) break true;
        } else false;
        if (paste_fd == null and w.wake_fd == null and !has_wake_fds) {
            try w.conn.dispatchTimeout(@intCast(@min(timeout_ms, std.math.maxInt(i32))));
            w.serviceRepeat(nowNs());
            return;
        }
        try w.conn.flush();
        if (try w.conn.dispatchPending() == 0) {
            const ms = @min(timeout_ms, w.clipboard.pasteTimeoutMs() orelse timeout_ms, std.math.maxInt(i32));
            var fds: [3 + 4]linux.pollfd = undefined;
            var n: usize = 0;
            for ([_]?linux.fd_t{ w.conn.conn.fd, paste_fd, w.wake_fd }) |fd| if (fd) |f| {
                fds[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            for (w.wake_fds) |fd| if (fd) |f| {
                fds[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            _ = linux.poll(&fds, n, @intCast(ms));
            _ = try w.conn.dispatchPending();
        }
        w.clipboard.service();
        w.serviceRepeat(nowNs());
    }

    fn repeatTimeoutMs(w: *const WaylandWindow, now_ns: u64) ?u64 {
        const rep = w.repeat orelse return null;
        if (w.repeat_rate == 0) return null;
        if (now_ns >= rep.next_ns) return 0;
        return std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
    }

    pub fn serviceRepeat(w: *WaylandWindow, now_ns: u64) void {
        const rep = &(w.repeat orelse return);
        if (w.repeat_rate == 0) {
            w.repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, w.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        w.pushInput(.{ .key = .{ .code = rep.code, .pressed = true } });
    }

    pub fn applyConfigure(w: *WaylandWindow) !?[2]u32 {
        const serial = w.pending_serial orelse return null;
        w.pending_serial = null;
        const size = [2]u32{
            if (w.next_size[0] > 0) @intCast(w.next_size[0]) else w.width,
            if (w.next_size[1] > 0) @intCast(w.next_size[1]) else w.height,
        };
        var m = try w.xdg_surface.request(p.xdg_surface.request.ack_configure);
        m.uint(serial).end();
        if (size[0] == w.width and size[1] == w.height) return null;
        w.width = size[0];
        w.height = size[1];
        return size;
    }

    /// Acquires a free `wl_shm` buffer of the window's current size and returns
    /// its CPU pixel slice as a `gfx.software.Image`.
    pub fn beginFrame(w: *WaylandWindow) !gfx.software.Image {
        const i = w.back orelse try w.pickBack();
        w.back = i;
        return w.buffers[i].?.image();
    }

    /// How many frames ago the buffer `beginFrame` gave was last drawn: 1
    /// if in the frame before, 0 if never.
    pub fn bufferAge(w: *const WaylandWindow) u32 {
        const i = w.back orelse return 0;
        const b = &w.buffers[i].?;
        if (b.drawn == 0) return 0;
        return @intCast(@min(w.frames + 1 - b.drawn, std.math.maxInt(u32)));
    }

    pub fn show(w: *WaylandWindow) !void {
        return w.showDamaged(null);
    }

    pub fn showDamaged(w: *WaylandWindow, damage: ?[]const gfx.Viewport) !void {
        const i = w.back orelse return error.NoFrameBegun;
        try w.showBuffer(i, damage);
        w.back = null;
    }

    fn showBuffer(w: *WaylandWindow, i: usize, damage: ?[]const gfx.Viewport) !void {
        while (w.frame_pending) {
            try w.conn.dispatch();
            if (w.suspended) w.releaseSpareBuffers();
        }
        const b = &w.buffers[i].?;
        var m = try w.surface.request(p.wl_surface.request.attach);
        m.uint(b.proxy.id).int(0).int(0).end();
        if (damage) |rects| {
            for (rects) |r| {
                m = try w.surface.request(p.wl_surface.request.damage_buffer);
                m.int(r.x).int(r.y).int(@intCast(r.width)).int(@intCast(r.height)).end();
            }
        } else {
            m = try w.surface.request(p.wl_surface.request.damage_buffer);
            m.int(0).int(0).int(@intCast(b.width)).int(@intCast(b.height)).end();
        }
        const cb = try w.conn.newObject(.{ .ptr = w, .handler = frameDone });
        m = try w.surface.request(p.wl_surface.request.frame);
        m.uint(cb.id).end();
        if (w.presentation) |pres| {
            const fb = try w.conn.newObject(.{ .ptr = w, .handler = feedbackEvent });
            m = try pres.request(p.wp_presentation.request.feedback);
            m.uint(w.surface.id).uint(fb.id).end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        b.busy = true;
        w.frames += 1;
        b.drawn = w.frames;
        w.frame_pending = true;
    }

    pub fn takeInput(w: *WaylandWindow) []const InputEvent {
        defer w.input_len = 0;
        return w.input[0..w.input_len];
    }

    fn pickBack(w: *WaylandWindow) !usize {
        while (true) {
            var empty: ?usize = null;
            var stale: ?usize = null;
            for (&w.buffers, 0..) |*slot, i| {
                if (slot.*) |*b| {
                    if (b.busy) continue;
                    if (b.width == w.width and b.height == w.height) return i;
                    stale = i;
                } else empty = i;
            }
            if (stale) |i| {
                w.freeBuffer(&w.buffers[i].?, &w.buffers[i]);
                empty = i;
            }
            if (empty) |i| {
                w.buffers[i] = try w.allocBuffer(i);
                return i;
            }
            try w.conn.dispatch();
        }
    }

    pub fn releaseSpareBuffers(w: *WaylandWindow) void {
        for (&w.buffers, 0..) |*slot, i| if (slot.*) |*b| {
            if (b.busy or w.back == i) continue;
            w.freeBuffer(b, slot);
        };
    }

    fn allocBuffer(w: *WaylandWindow, slot: usize) !Buffer {
        const stride = w.width * 4;
        const size: usize = @as(usize, stride) * @as(usize, w.height);
        const rc = linux.memfd_create("facet-shm", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.OutOfMemory;
        const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) return error.OutOfMemory;
        const pixels: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(map_rc))[0..size];
        errdefer _ = linux.munmap(pixels.ptr, size);

        const pool = try w.conn.newObject(null);
        var m = try w.shm.request(p.wl_shm.request.create_pool);
        m.uint(pool.id).fd(fd).int(@intCast(size)).end();

        const proxy = try w.conn.newObject(.{ .ptr = &w.buffers[slot], .handler = bufferEvent });
        m = try pool.request(p.wl_shm_pool.request.create_buffer);
        m.uint(proxy.id).int(0).int(@intCast(w.width)).int(@intCast(w.height)).int(@intCast(stride)).uint(p.wl_shm.format.xrgb8888).end();

        return .{
            .fd = fd,
            .pixels = pixels,
            .pool = pool,
            .proxy = proxy,
            .width = w.width,
            .height = w.height,
        };
    }

    fn freeBuffer(w: *WaylandWindow, b: *Buffer, slot: *?Buffer) void {
        if (b.proxy.request(p.wl_buffer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(b.proxy.id);
        if (b.pool.request(p.wl_shm_pool.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(b.pool.id);
        _ = linux.munmap(b.pixels.ptr, b.pixels.len);
        _ = linux.close(b.fd);
        slot.* = null;
    }

    fn bufferEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const slot: *?Buffer = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_buffer.event.release) if (slot.*) |*b| {
            b.busy = false;
        };
    }

    fn frameDone(ptr: ?*anyopaque, d: *client.Display, id: u32, _: u16, _: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        d.forget(id);
        w.frame_pending = false;
    }

    fn surfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_surface.event.preferred_buffer_scale) {
            const factor = r.int() catch return;
            if (factor > 0) w.scale = @intCast(factor);
        }
    }

    fn presentationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wp_presentation.event.clock_id) {
            w.presentation_clock_id = r.uint() catch return;
        }
    }

    fn feedbackEvent(ptr: ?*anyopaque, d: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wp_presentation_feedback.event.sync_output => {
                _ = r.uint() catch return;
            },
            p.wp_presentation_feedback.event.presented => {
                defer d.forget(id);
                const tv_sec_hi = r.uint() catch return;
                const tv_sec_lo = r.uint() catch return;
                const tv_nsec = r.uint() catch return;
                const refresh = r.uint() catch return;
                const seq_hi = r.uint() catch return;
                const seq_lo = r.uint() catch return;
                const flags = r.uint() catch return;
                const secs = (@as(u64, tv_sec_hi) << 32) | tv_sec_lo;
                w.presented_ns = secs * std.time.ns_per_s + tv_nsec;
                if (refresh > 0) w.refresh_ns = refresh;
                w.presentation_seq = (@as(u64, seq_hi) << 32) | seq_lo;
                w.presentation_flags = flags;
                w.presented_frames += 1;
            },
            p.wp_presentation_feedback.event.discarded => {
                d.forget(id);
                w.discarded_frames += 1;
            },
            else => {},
        }
    }

    fn onDragEnter(ptr: ?*anyopaque, pos: [2]f32, _: ?[]const u8) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drag_enter = pos });
    }

    fn onDragMotion(ptr: ?*anyopaque, pos: [2]f32) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (w.input_len > 0 and w.input[w.input_len - 1] == .drag_motion) {
            w.input[w.input_len - 1] = .{ .drag_motion = pos };
            return;
        }
        w.pushInput(.{ .drag_motion = pos });
    }

    fn onDragLeave(ptr: ?*anyopaque) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.drag_leave);
    }

    fn onDragDrop(ptr: ?*anyopaque, pos: [2]f32, _: []const u8, _: []const u8, _: u32) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drop = pos });
    }

    fn textInputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_text_input_v3.event.enter => {
                _ = r.uint() catch return;
                w.text_input_entered = true;
                if (w.text_input_enabled) if (w.text_input) |ti| {
                    w.sendTextInputState(ti, true);
                };
            },
            p.zwp_text_input_v3.event.leave => {
                _ = r.uint() catch return;
                w.text_input_entered = false;
                w.text_input_pending_preedit = null;
                w.text_input_pending_commit = null;
                w.text_input_pending_delete = null;
            },
            p.zwp_text_input_v3.event.preedit_string => {
                const text = (r.string() catch return) orelse "";
                const begin = r.int() catch return;
                const end = r.int() catch return;
                var pre: @TypeOf(w.text_input_pending_preedit.?) = .{ .cursor_begin = begin, .cursor_end = end };
                const n: u8 = @intCast(@min(text.len, pre.buf.len));
                @memcpy(pre.buf[0..n], text[0..n]);
                pre.len = n;
                w.text_input_pending_preedit = pre;
            },
            p.zwp_text_input_v3.event.commit_string => {
                const text = (r.string() catch return) orelse "";
                var com: @TypeOf(w.text_input_pending_commit.?) = .{};
                const n: u8 = @intCast(@min(text.len, com.buf.len));
                @memcpy(com.buf[0..n], text[0..n]);
                com.len = n;
                w.text_input_pending_commit = com;
            },
            p.zwp_text_input_v3.event.delete_surrounding_text => {
                const before = r.uint() catch return;
                const after = r.uint() catch return;
                w.text_input_pending_delete = .{ .before_length = before, .after_length = after };
            },
            p.zwp_text_input_v3.event.done => {
                _ = r.uint() catch return;
                if (w.text_input_pending_delete) |del| {
                    w.text_input_pending_delete = null;
                    w.pushInput(.{ .text_delete_surrounding = .{ .before_length = del.before_length, .after_length = del.after_length } });
                }
                if (w.text_input_pending_commit) |com| {
                    w.text_input_pending_commit = null;
                    if (com.len > 0) {
                        var ev: InputEvent = .{ .text_commit = .{ .len = com.len } };
                        @memcpy(ev.text_commit.buf[0..com.len], com.buf[0..com.len]);
                        w.pushInput(ev);
                    }
                }
                if (w.text_input_pending_preedit) |pre| {
                    w.text_input_pending_preedit = null;
                    w.text_input_has_preedit = pre.len > 0;
                    var ev: InputEvent = .{ .text_preedit = .{ .len = pre.len, .cursor_begin = pre.cursor_begin, .cursor_end = pre.cursor_end } };
                    @memcpy(ev.text_preedit.buf[0..pre.len], pre.buf[0..pre.len]);
                    w.pushInput(ev);
                } else if (w.text_input_has_preedit) {
                    w.text_input_has_preedit = false;
                    w.pushInput(.{ .text_preedit = .{} });
                }
            },
            else => {},
        }
    }

    fn pushInput(w: *WaylandWindow, e: InputEvent) void {
        if (e == .motion and w.input_len > 0 and w.input[w.input_len - 1] == .motion) {
            w.input[w.input_len - 1] = e;
            return;
        }
        if (e == .touch_motion and w.input_len > 0) switch (w.input[w.input_len - 1]) {
            .touch_motion => |last| if (last.id == e.touch_motion.id) {
                w.input[w.input_len - 1] = e;
                return;
            },
            else => {},
        };
        if (w.input_len == w.input.len) return;
        w.input[w.input_len] = e;
        w.input_len += 1;
    }

    fn seatEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_seat.event.capabilities) return;
        const caps = r.uint() catch return;
        if (caps & p.wl_seat.capability.pointer != 0 and w.pointer == null) {
            const pointer = d.newObject(.{ .ptr = w, .handler = pointerEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_pointer) catch return;
            m.uint(pointer.id).end();
            w.pointer = pointer;
            if (w.cursor_shape_manager) |manager| {
                const device = d.newObject(null) catch return;
                m = manager.request(p.wp_cursor_shape_manager_v1.request.get_pointer) catch return;
                m.uint(device.id).uint(pointer.id).end();
                w.cursor_device = device;
            }
            if (w.relative_pointer_manager) |manager| {
                const rel = d.newObject(.{ .ptr = w, .handler = relativeEvent }) catch return;
                m = manager.request(p.zwp_relative_pointer_manager_v1.request.get_relative_pointer) catch return;
                m.uint(rel.id).uint(pointer.id).end();
                w.relative_pointer = rel;
            }
        }
        if (caps & p.wl_seat.capability.touch != 0 and w.touch == null) {
            const touch = d.newObject(.{ .ptr = w, .handler = touchEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_touch) catch return;
            m.uint(touch.id).end();
            w.touch = touch;
        }
        if (caps & p.wl_seat.capability.keyboard != 0 and w.keyboard == null) {
            const keyboard = d.newObject(.{ .ptr = w, .handler = keyboardEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_keyboard) catch return;
            m.uint(keyboard.id).end();
            w.keyboard = keyboard;
        }
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_pointer.event.enter, p.wl_pointer.event.motion => {
                const first = r.uint() catch return;
                if (opcode == p.wl_pointer.event.enter) {
                    _ = r.uint() catch return;
                    w.enter_serial = first;
                    w.buttons_down = 0;
                    w.cursor_shape = p.wp_cursor_shape_device_v1.shape.default;
                }
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                w.pointer_pos = .{ @floatCast(x), @floatCast(y) };
                w.updateCursor();
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_pointer.button_state.pressed;
                if (pressed) {
                    w.press_serial = serial;
                    w.clipboard.serial = serial;
                } else {
                    w.press_serial = 0;
                }
                if (pressed and code == p.input.btn_left) {
                    const edges = w.edgesAt(w.pointer_pos);
                    if (edges != 0) if (w.seat) |seat| {
                        var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                        m.uint(seat.id).uint(serial).uint(edges).end();
                        w.conn.flush() catch {};
                        return;
                    };
                }
                const bit = @as(u32, 1) << @intCast(@min(code -% p.input.btn_left, 31));
                w.buttons_down = if (pressed) w.buttons_down | bit else w.buttons_down & ~bit;
                if (!pressed and w.buttons_down == 0) w.updateCursor();
                w.pushInput(.{ .button = .{ .pos = w.pointer_pos, .code = code, .pressed = pressed } });
            },
            p.wl_pointer.event.axis => {
                _ = r.uint() catch return;
                const axis = r.uint() catch return;
                const value: f32 = @floatCast(r.fixed() catch return);
                const vertical = axis == p.wl_pointer.axis.vertical_scroll;
                w.pushInput(.{ .scroll = .{ .pos = w.pointer_pos, .dx = if (vertical) 0 else value, .dy = if (vertical) value else 0 } });
            },
            p.wl_pointer.event.leave => {
                w.buttons_down = 0;
                w.press_serial = 0;
                w.cursor_shape = null;
                w.pushInput(.leave);
            },
            else => {},
        }
    }

    fn touchEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_touch.event.down => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const pos: [2]f32 = .{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) };
                w.press_serial = serial;
                w.clipboard.serial = serial;
                const edges = w.edgesAt(pos);
                if (edges != 0) if (w.seat) |seat| {
                    var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                    m.uint(seat.id).uint(serial).uint(edges).end();
                    w.conn.flush() catch {};
                    return;
                };
                w.pushInput(.{ .touch_down = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.motion => {
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const pos: [2]f32 = .{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) };
                w.pushInput(.{ .touch_motion = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.up => {
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                w.press_serial = 0;
                w.pushInput(.{ .touch_up = @bitCast(r.uint() catch return) });
            },
            p.wl_touch.event.cancel => {
                w.press_serial = 0;
                w.pushInput(.touch_cancel);
            },
            else => {},
        }
    }

    pub fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_keyboard.event.keymap => {
                _ = r.uint() catch return;
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                const size = r.uint() catch return;
                if (keyboardFromKeymap(fd, size)) |k| w.layout = k;
            },
            p.wl_keyboard.event.key => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_keyboard.key_state.pressed;
                if (pressed) w.clipboard.serial = serial;
                if (code < 256) w.keys_down.setValue(code, pressed);
                if (pressed) {
                    if (!isModifierKey(code) and w.repeat_rate > 0) {
                        w.repeat = .{
                            .code = code,
                            .next_ns = nowNs() + @as(u64, w.repeat_delay_ms) * std.time.ns_per_ms,
                        };
                    }
                } else if (w.repeat) |rep| {
                    if (rep.code == code) w.repeat = null;
                }
                w.pushInput(.{ .key = .{ .code = code, .pressed = pressed } });
            },
            p.wl_keyboard.event.leave => {
                w.repeat = null;
                var it = w.keys_down.iterator(.{});
                while (it.next()) |code| {
                    w.pushInput(.{ .key = .{ .code = @intCast(code), .pressed = false } });
                }
                w.keys_down = .initEmpty();
            },
            p.wl_keyboard.event.repeat_info => {
                const rate = r.int() catch return;
                const delay = r.int() catch return;
                w.repeat_rate = @intCast(@max(rate, 0));
                w.repeat_delay_ms = @intCast(@max(delay, 0));
                if (w.repeat_rate == 0) w.repeat = null;
            },
            else => {},
        }
    }

    fn isModifierKey(code: u32) bool {
        return switch (code) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
    }

    fn wmBaseEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_wm_base.event.ping) return;
        const serial = r.uint() catch return;
        var m = w.wm_base.request(p.xdg_wm_base.request.pong) catch return;
        m.uint(serial).end();
    }

    fn xdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.xdg_surface.event.configure) w.pending_serial = r.uint() catch return;
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.xdg_toplevel.event.configure => {
                w.next_size = .{ r.int() catch 0, r.int() catch 0 };
                const states = r.array() catch &.{};
                var suspended = false;
                var maximized = false;
                var fullscreen = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                    p.xdg_toplevel.state.suspended => suspended = true,
                    p.xdg_toplevel.state.maximized => maximized = true,
                    p.xdg_toplevel.state.fullscreen => fullscreen = true,
                    else => {},
                };
                if (suspended) w.repeat = null;
                w.suspended = suspended;
                w.maximized = maximized;
                w.fullscreen = fullscreen;
            },
            p.xdg_toplevel.event.close => w.closed = true,
            else => {},
        }
    }
};

fn keyboardFromKeymap(fd: linux.fd_t, size: u32) ?Keyboard {
    if (size == 0 or size > 1 << 20) return null;
    const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const text = @as([*]const u8, @ptrFromInt(rc))[0..size];
    defer _ = linux.munmap(text.ptr, size);
    return layoutNamed(text);
}

fn layoutNamed(keymap: []const u8) ?Keyboard {
    const key = "xkb_symbols \"";
    const at = std.mem.indexOf(u8, keymap, key) orelse return null;
    const rest = keymap[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return Keyboard.fromCode(rest[0..end]);
}

test "the layout is named in the keymap" {
    try std.testing.expectEqual(Keyboard.gb, layoutNamed("xkb_keymap {\nxkb_symbols \"gb\" {\n").?);
    try std.testing.expect(layoutNamed("xkb_symbols \"pc+us+inet(evdev)\" {") == null);
    try std.testing.expect(layoutNamed("nothing") == null);
}

test "held keys repeat after the delay, except modifiers, and stop on release or leave" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
    };
    var disp: client.Display = undefined;

    const repeat_msg = [_]u32{ 25, 200 };
    var r_info = wire.Reader{ .data = std.mem.sliceAsBytes(&repeat_msg), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.repeat_info, &r_info);
    try std.testing.expectEqual(@as(u32, 25), win.repeat_rate);
    try std.testing.expectEqual(@as(u32, 200), win.repeat_delay_ms);

    const shift_down = [_]u32{ 1, 0, 42, p.wl_keyboard.key_state.pressed };
    var r_shift = wire.Reader{ .data = std.mem.sliceAsBytes(&shift_down), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_shift);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    const a_down = [_]u32{ 2, 0, 30, p.wl_keyboard.key_state.pressed };
    var r_a_down = wire.Reader{ .data = std.mem.sliceAsBytes(&a_down), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_down);
    try std.testing.expectEqual(@as(u32, 30), win.repeat.?.code);
    try std.testing.expectEqual(@as(usize, 1), win.takeInput().len);

    const first_due = win.repeat.?.next_ns;
    win.serviceRepeat(first_due - 1);
    try std.testing.expectEqual(@as(usize, 0), win.takeInput().len);
    try std.testing.expectEqual(@as(?u64, 1), win.repeatTimeoutMs(first_due - 1));

    win.serviceRepeat(first_due);
    const rep1 = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), rep1.len);
    try std.testing.expectEqual(@as(u32, 30), rep1[0].key.code);
    try std.testing.expect(rep1[0].key.pressed);
    try std.testing.expectEqual(first_due + 40 * std.time.ns_per_ms, win.repeat.?.next_ns);

    const a_up = [_]u32{ 3, 0, 30, p.wl_keyboard.key_state.released };
    var r_a_up = wire.Reader{ .data = std.mem.sliceAsBytes(&a_up), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_up);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    const leave_msg = [_]u32{ 4, 1 };
    var r_leave = wire.Reader{ .data = std.mem.sliceAsBytes(&leave_msg), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.leave, &r_leave);
    const left = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqual(@as(u32, 42), left[0].key.code);
    try std.testing.expect(!left[0].key.pressed);
}
