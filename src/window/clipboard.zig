//! The system's clipboard, for text, over Wayland (wl_data_device): what
//! the toolkit's `WindowUi.clipboard` is given (`ui.Clipboard.of(&window.clipboard)`).
//!
//! Copying makes a data source offering the text, set as the selection
//! (the shell takes it only from the window with the keyboard, with the
//! serial of the input that asked); the shell asks for it (`send`) when
//! another client pastes. Pasting asks the clipboard's offer for text
//! through a pipe and returns at once: the text comes to a `Sink` once it
//! has all arrived, read as the window's event loop sees it come
//! (`WaylandWindow.wait` and `poll` watch the pipe, and call `service`), or
//! nothing if it does not come within `paste_timeout_ms`. Text this window
//! copied is pasted from its own copy, without the shell, at once.

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

/// The text types offered, and taken in this order of preference.
const mime_types = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };

/// The most text pasted.
pub const max_paste = 1024 * 1024;
/// How long pasting waits for the text.
pub const paste_timeout_ms = 1000;

/// Where pasted text goes: `f(ctx, text)`, with the text (valid during the
/// call), or null if there was none.
pub const Sink = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, text: ?[]const u8) void,
};

fn nowMs(io: std.Io) u64 {
    return @import("window.zig").nowNs(io) / std.time.ns_per_ms;
}

pub const DragCallbacks = struct {
    ctx: ?*anyopaque = null,
    enter: ?*const fn (ctx: ?*anyopaque, pos: [2]f32, mime: ?[]const u8) void = null,
    motion: ?*const fn (ctx: ?*anyopaque, pos: [2]f32) void = null,
    leave: ?*const fn (ctx: ?*anyopaque) void = null,
    drop: ?*const fn (ctx: ?*anyopaque, pos: [2]f32, data: []const u8, mime: []const u8, action: u32) void = null,
};

pub const DroppedData = struct {
    pos: [2]f32,
    data: []const u8,
    mime: []const u8,
    action: u32,
};

pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    /// What it waits and reads through (the connection's, from `attach`).
    io: std.Io = undefined,
    conn: *client.Display = undefined,
    attached: bool = false,
    device: ?client.Proxy = null,
    manager: ?client.Proxy = null,
    seat: ?client.Proxy = null,
    /// The serial of the latest key or button press (set by the window).
    serial: u32 = 0,
    /// What the clipboard holds (an offer), and the best text type it
    /// has, if any.
    offer: ?u32 = null,
    offer_mime: ?usize = null,
    /// An offer being described (its types come before `selection` or `enter`).
    incoming: ?u32 = null,
    incoming_mime: ?usize = null,
    incoming_first_mime: [64]u8 = undefined,
    incoming_first_mime_len: usize = 0,
    incoming_source_actions: u32 = 0,
    /// What this window copied, while it is the selection.
    source: ?client.Proxy = null,
    text: []u8 = &.{},
    /// A paste under way: the pipe it comes through (non-blocking), what
    /// has come, where it goes, and when to give up.
    pending: ?struct { fd: linux.fd_t, got: std.ArrayList(u8) = .empty, sink: Sink, deadline_ms: u64 } = null,

    /// Outgoing drag-and-drop source state (`startDrag`).
    drag_source: ?client.Proxy = null,
    drag_data: []u8 = &.{},
    drag_mime: []u8 = &.{},
    drag_action: u32 = 0,
    drag_accepted: bool = false,
    drag_dropped: bool = false,
    drag_finished: bool = false,
    drag_cancelled: bool = false,

    /// Incoming drag-and-drop offer state (`enter`, `motion`, `leave`, `drop`).
    drag_callbacks: DragCallbacks = .{},
    drag_offer: ?u32 = null,
    drag_offer_mime: [64]u8 = undefined,
    drag_offer_mime_len: usize = 0,
    drag_source_actions: u32 = 0,
    drag_negotiated_action: u32 = 0,
    drag_enter_serial: u32 = 0,
    drag_pos: [2]f32 = .{ 0, 0 },
    dragging_over: bool = false,
    /// An incoming drop being read from a pipe.
    pending_drop: ?struct {
        fd: linux.fd_t,
        offer: u32,
        pos: [2]f32,
        action: u32,
        mime: [64]u8,
        mime_len: usize,
        got: std.ArrayList(u8) = .empty,
        deadline_ms: u64,
    } = null,
    /// The most recently completed drop payload, owned by `Clipboard`.
    last_drop_data: []u8 = &.{},
    last_drop_mime: [64]u8 = undefined,
    last_drop_mime_len: usize = 0,
    last_drop_pos: [2]f32 = .{ 0, 0 },
    last_drop_action: u32 = 0,
    has_drop: bool = false,
    /// What a read of a paste or drop through `io` reads into.
    read_buf: [4096]u8 = undefined,
    read_vec: [1][]u8 = undefined,

    /// Starts using the data device of `seat`, if the shell has one.
    pub fn attach(c: *Clipboard, conn: *client.Display, manager: ?client.Proxy, seat: ?client.Proxy) !void {
        c.conn = conn;
        c.attached = true;
        c.io = conn.conn.io;
        c.manager = manager;
        c.seat = seat;
        const m = manager orelse return;
        const s = seat orelse return;
        const device = try conn.newObject(.{ .ptr = c, .handler = deviceEvent });
        var req = try m.request(p.wl_data_device_manager.request.get_data_device);
        req.uint(device.id).uint(s.id).end();
        c.device = device;
    }

    pub fn deinit(c: *Clipboard) void {
        c.cancelPaste();
        c.cancelDrop();
        c.dropSource();
        c.dropDragSource();
        if (c.offer) |old| {
            c.destroyOffer(old);
            if (c.incoming == old) c.incoming = null;
            c.offer = null;
            c.offer_mime = null;
        }
        if (c.incoming) |old| {
            c.destroyOffer(old);
            c.incoming = null;
            c.incoming_mime = null;
        }
        if (c.device) |dev| {
            if (dev.request(p.wl_data_device.request.release)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            c.conn.forget(dev.id);
            c.device = null;
        }
        if (c.attached) {
            c.conn.forgetAll(c);
            c.attached = false;
        }
        c.gpa.free(c.last_drop_data);
        c.last_drop_data = &.{};
    }

    /// Puts `text` on the clipboard.
    pub fn copy(c: *Clipboard, text: []const u8) void {
        const manager = c.manager orelse return;
        const device = c.device orelse return;
        c.dropSource();
        c.text = c.gpa.dupe(u8, text) catch return;
        const source = c.conn.newObject(.{ .ptr = c, .handler = sourceEvent }) catch return;
        var m = manager.request(p.wl_data_device_manager.request.create_data_source) catch return;
        m.uint(source.id).end();
        for (mime_types) |mime| {
            m = source.request(p.wl_data_source.request.offer) catch return;
            m.string(mime).end();
        }
        m = device.request(p.wl_data_device.request.set_selection) catch return;
        m.uint(source.id).uint(c.serial).end();
        c.source = source;
        c.conn.flush() catch {};
    }

    /// Starts a Wayland drag-and-drop operation from `origin` (with an
    /// optional `icon` surface), offering `data` as `mime` with allowed
    /// `actions` (`wl_data_device_manager.dnd_action` bitmask).
    pub fn startDrag(c: *Clipboard, origin: client.Proxy, icon: ?client.Proxy, mime: []const u8, data: []const u8, actions: u32) bool {
        const manager = c.manager orelse return false;
        const device = c.device orelse return false;
        if (c.serial == 0) return false;
        c.dropDragSource();
        c.drag_action = 0;
        c.drag_accepted = false;
        c.drag_dropped = false;
        c.drag_finished = false;
        c.drag_cancelled = false;
        c.drag_data = c.gpa.dupe(u8, data) catch return false;
        c.drag_mime = c.gpa.dupe(u8, mime) catch {
            c.gpa.free(c.drag_data);
            c.drag_data = &.{};
            return false;
        };
        const source = c.conn.newObject(.{ .ptr = c, .handler = dragSourceEvent }) catch {
            c.dropDragSource();
            return false;
        };
        var m = manager.request(p.wl_data_device_manager.request.create_data_source) catch {
            c.conn.forget(source.id);
            c.dropDragSource();
            return false;
        };
        m.uint(source.id).end();
        m = source.request(p.wl_data_source.request.offer) catch {
            c.drag_source = source;
            c.dropDragSource();
            return false;
        };
        m.string(mime).end();
        const is_text = for (mime_types) |tm| {
            if (std.mem.eql(u8, tm, mime)) break true;
        } else false;
        if (is_text) {
            for (mime_types) |tm| if (!std.mem.eql(u8, tm, mime)) {
                if (source.request(p.wl_data_source.request.offer)) |m0| {
                    var req = m0;
                    req.string(tm).end();
                } else |_| {}
            };
        }
        if (actions != 0) {
            m = source.request(p.wl_data_source.request.set_actions) catch {
                c.drag_source = source;
                c.dropDragSource();
                return false;
            };
            m.uint(actions).end();
        }
        m = device.request(p.wl_data_device.request.start_drag) catch {
            c.drag_source = source;
            c.dropDragSource();
            return false;
        };
        m.uint(source.id).uint(origin.id).uint(if (icon) |ic| ic.id else 0).uint(c.serial).end();
        c.drag_source = source;
        c.conn.flush() catch {};
        return true;
    }

    /// Updates the MIME type and actions accepted for the current incoming
    /// drag offer.
    pub fn acceptDrag(c: *Clipboard, mime: ?[]const u8, dnd_actions: u32, preferred_action: u32) void {
        const offer_id = c.drag_offer orelse return;
        const proxy = client.Proxy{ .display = c.conn, .id = offer_id };
        if (proxy.request(p.wl_data_offer.request.accept)) |m0| {
            var m = m0;
            m.uint(c.drag_enter_serial).string(mime).end();
        } else |_| {}
        if (proxy.request(p.wl_data_offer.request.set_actions)) |m0| {
            var m = m0;
            m.uint(dnd_actions).uint(preferred_action).end();
        } else |_| {}
        c.conn.flush() catch {};
    }

    /// Returns and clears the most recently completed incoming drop, if any.
    /// The returned slices are valid until the next drop or `deinit`.
    pub fn takeDrop(c: *Clipboard) ?DroppedData {
        if (!c.has_drop) return null;
        c.has_drop = false;
        return .{
            .pos = c.last_drop_pos,
            .data = c.last_drop_data,
            .mime = c.last_drop_mime[0..c.last_drop_mime_len],
            .action = c.last_drop_action,
        };
    }

    /// Asks for the clipboard's text, which goes to `sink` (once; null if
    /// it has none): this window's own copy at once, or what the client
    /// that copied it writes, as it comes (see `service`).
    pub fn paste(c: *Clipboard, sink: Sink) void {
        c.cancelPaste();
        if (c.source != null) return sink.f(sink.ctx, c.text);
        const offer = c.offer orelse return sink.f(sink.ctx, null);
        const mime = mime_types[c.offer_mime orelse return sink.f(sink.ctx, null)];
        var fds: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return sink.f(sink.ctx, null);
        const flags = linux.fcntl(fds[0], linux.F.GETFL, 0);
        _ = linux.fcntl(fds[0], linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
        var m = (client.Proxy{ .display = c.conn, .id = offer }).request(p.wl_data_offer.request.receive) catch {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
            return sink.f(sink.ctx, null);
        };
        m.string(mime).fd(fds[1]).end();
        c.conn.flush() catch {};
        c.pending = .{ .fd = fds[0], .sink = sink, .deadline_ms = nowMs(c.io) + paste_timeout_ms };
    }

    /// The pipe a paste or drop comes through, for the event loop to wait on.
    pub fn pasteFd(c: *const Clipboard) ?linux.fd_t {
        if (c.pending) |pd| return pd.fd;
        if (c.pending_drop) |dd| return dd.fd;
        return null;
    }

    /// The read that waits for more of a paste or drop under way, through
    /// `io` (null if none is): give `readDone` its result.
    pub fn readOperation(c: *Clipboard) ?std.Io.Operation {
        const fd = c.pasteFd() orelse return null;
        c.read_vec = .{&c.read_buf};
        return .{ .file_read_streaming = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = true } }, .data = &c.read_vec } };
    }

    /// Takes what a `readOperation` read (the rest is read by `service`).
    pub fn readDone(c: *Clipboard, result: std.Io.Operation.Result) void {
        const n = result.file_read_streaming catch |e| switch (e) {
            error.WouldBlock => return,
            else => {
                if (c.pending != null) c.finishPaste(false) else c.finishDrop(false);
                return;
            },
        };
        if (c.pending) |*pd| {
            c.took(&pd.got, c.read_buf[0..n], finishPaste);
        } else if (c.pending_drop) |*dd| {
            c.took(&dd.got, c.read_buf[0..n], finishDrop);
        }
    }

    /// Keeps `bytes` of a paste or drop (none: it has all come), finishing
    /// it if it has all come or is too big.
    fn took(c: *Clipboard, got: *std.ArrayList(u8), bytes: []const u8, comptime finish: fn (*Clipboard, bool) void) void {
        if (bytes.len == 0) return finish(c, true);
        got.appendSlice(c.gpa, bytes[0..@min(bytes.len, max_paste -| got.items.len)]) catch return finish(c, false);
        if (got.items.len >= max_paste) finish(c, true);
    }

    /// How long until a paste or drop under way gives up (null if none is).
    pub fn pasteTimeoutMs(c: *const Clipboard) ?u64 {
        const now = nowMs(c.io);
        var best: ?u64 = null;
        if (c.pending) |pd| best = pd.deadline_ms -| now;
        if (c.pending_drop) |dd| {
            const rem = dd.deadline_ms -| now;
            best = if (best) |b| @min(b, rem) else rem;
        }
        return best;
    }

    /// Reads what has come of a paste or drop under way, without waiting;
    /// once it has all come (or the time is up), gives it to its sink.
    pub fn service(c: *Clipboard) void {
        if (c.pending) |*pd| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(pd.fd, &buf, buf.len);
                switch (linux.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) {
                            c.finishPaste(true);
                            break;
                        }
                        pd.got.appendSlice(c.gpa, buf[0..@min(n, max_paste -| pd.got.items.len)]) catch {
                            c.finishPaste(false);
                            break;
                        };
                        if (pd.got.items.len >= max_paste) {
                            c.finishPaste(true);
                            break;
                        }
                    },
                    .INTR => {},
                    .AGAIN => {
                        if (nowMs(c.io) >= pd.deadline_ms) c.finishPaste(false);
                        break;
                    },
                    else => {
                        c.finishPaste(false);
                        break;
                    },
                }
            }
        }
        if (c.pending_drop) |*dd| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(dd.fd, &buf, buf.len);
                switch (linux.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) {
                            c.finishDrop(true);
                            break;
                        }
                        dd.got.appendSlice(c.gpa, buf[0..@min(n, max_paste -| dd.got.items.len)]) catch {
                            c.finishDrop(false);
                            break;
                        };
                        if (dd.got.items.len >= max_paste) {
                            c.finishDrop(true);
                            break;
                        }
                    },
                    .INTR => {},
                    .AGAIN => {
                        if (nowMs(c.io) >= dd.deadline_ms) c.finishDrop(false);
                        break;
                    },
                    else => {
                        c.finishDrop(false);
                        break;
                    },
                }
            }
        }
    }

    fn finishPaste(c: *Clipboard, ok: bool) void {
        var pd = c.pending orelse return;
        c.pending = null;
        _ = linux.close(pd.fd);
        defer pd.got.deinit(c.gpa);
        pd.sink.f(pd.sink.ctx, if (ok) pd.got.items else null);
    }

    pub fn cancelPaste(c: *Clipboard) void {
        var pd = c.pending orelse return;
        c.pending = null;
        _ = linux.close(pd.fd);
        pd.got.deinit(c.gpa);
    }

    fn finishDrop(c: *Clipboard, ok: bool) void {
        var dd = c.pending_drop orelse return;
        c.pending_drop = null;
        _ = linux.close(dd.fd);
        defer dd.got.deinit(c.gpa);
        if (ok) {
            if ((client.Proxy{ .display = c.conn, .id = dd.offer }).request(p.wl_data_offer.request.finish)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
        }
        c.destroyOffer(dd.offer);
        c.conn.flush() catch {};
        if (!ok) return;
        c.recordDrop(dd.pos, dd.got.items, dd.mime[0..dd.mime_len], dd.action);
    }

    pub fn recordDrop(c: *Clipboard, pos: [2]f32, data: []const u8, mime: []const u8, action: u32) void {
        const duped = c.gpa.dupe(u8, data) catch return;
        c.gpa.free(c.last_drop_data);
        c.last_drop_data = duped;
        const mlen = @min(mime.len, c.last_drop_mime.len);
        @memcpy(c.last_drop_mime[0..mlen], mime[0..mlen]);
        c.last_drop_mime_len = mlen;
        c.last_drop_pos = pos;
        c.last_drop_action = action;
        c.has_drop = true;
        if (c.drag_callbacks.drop) |f| f(c.drag_callbacks.ctx, pos, duped, c.last_drop_mime[0..mlen], action);
    }

    pub fn cancelDrop(c: *Clipboard) void {
        if (c.pending_drop) |*dd| {
            _ = linux.close(dd.fd);
            dd.got.deinit(c.gpa);
            c.destroyOffer(dd.offer);
            c.pending_drop = null;
        }
        if (c.drag_offer) |old| {
            c.destroyOffer(old);
            c.drag_offer = null;
            c.drag_offer_mime_len = 0;
        }
    }

    fn dropSource(c: *Clipboard) void {
        if (c.source) |s| {
            if (s.request(p.wl_data_source.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            c.conn.setListener(s.id, .{ .ptr = null, .handler = drainSourceEvent }) catch c.conn.forget(s.id);
        }
        c.source = null;
        c.gpa.free(c.text);
        c.text = &.{};
    }

    fn dropDragSource(c: *Clipboard) void {
        if (c.drag_source) |s| {
            if (s.request(p.wl_data_source.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            c.conn.setListener(s.id, .{ .ptr = null, .handler = drainSourceEvent }) catch c.conn.forget(s.id);
        }
        c.drag_source = null;
        c.gpa.free(c.drag_data);
        c.drag_data = &.{};
        c.gpa.free(c.drag_mime);
        c.drag_mime = &.{};
    }

    fn drainSourceEvent(_: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        if (opcode == p.wl_data_source.event.send) {
            if (r.fd() catch null) |fd| _ = linux.close(fd);
        }
    }

    fn destroyOffer(c: *Clipboard, id: u32) void {
        if ((client.Proxy{ .display = c.conn, .id = id }).request(p.wl_data_offer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        c.conn.forget(id);
    }

    fn deviceEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_device.event.data_offer => {
                const id = r.uint() catch return;
                if (c.incoming) |old| if (old != c.offer and old != c.drag_offer) c.destroyOffer(old);
                c.incoming = id;
                c.incoming_mime = null;
                c.incoming_first_mime_len = 0;
                c.incoming_source_actions = 0;
                d.setListener(id, .{ .ptr = c, .handler = offerEvent }) catch {};
            },
            p.wl_data_device.event.enter => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const x: f32 = @floatCast(r.fixed() catch return);
                const y: f32 = @floatCast(r.fixed() catch return);
                const id = r.uint() catch return;
                if (c.drag_offer) |old| if (old != id) c.destroyOffer(old);
                c.drag_enter_serial = serial;
                c.drag_pos = .{ x, y };
                c.dragging_over = true;
                c.drag_offer = if (id == 0) null else id;
                c.drag_offer_mime_len = 0;
                c.drag_source_actions = 0;
                c.drag_negotiated_action = 0;
                if (id != 0 and c.incoming == id) {
                    c.incoming = null;
                    c.drag_source_actions = c.incoming_source_actions;
                    const chosen: ?[]const u8 = if (c.incoming_mime) |mi|
                        mime_types[mi]
                    else if (c.incoming_first_mime_len > 0)
                        c.incoming_first_mime[0..c.incoming_first_mime_len]
                    else
                        null;
                    if (chosen) |cm| {
                        const n = @min(cm.len, c.drag_offer_mime.len);
                        @memcpy(c.drag_offer_mime[0..n], cm[0..n]);
                        c.drag_offer_mime_len = n;
                    }
                    const A = p.wl_data_device_manager.dnd_action;
                    c.acceptDrag(
                        if (c.drag_offer_mime_len > 0) c.drag_offer_mime[0..c.drag_offer_mime_len] else null,
                        if (c.drag_offer_mime_len > 0) (A.copy | A.move) else A.none,
                        if (c.drag_offer_mime_len > 0) A.copy else A.none,
                    );
                } else if (c.incoming) |old| {
                    if (old != c.offer) c.destroyOffer(old);
                    c.incoming = null;
                }
                if (c.drag_callbacks.enter) |f| {
                    f(c.drag_callbacks.ctx, c.drag_pos, if (c.drag_offer_mime_len > 0) c.drag_offer_mime[0..c.drag_offer_mime_len] else null);
                }
            },
            p.wl_data_device.event.motion => {
                _ = r.uint() catch return;
                const x: f32 = @floatCast(r.fixed() catch return);
                const y: f32 = @floatCast(r.fixed() catch return);
                c.drag_pos = .{ x, y };
                if (c.drag_callbacks.motion) |f| f(c.drag_callbacks.ctx, c.drag_pos);
            },
            p.wl_data_device.event.leave => {
                c.dragging_over = false;
                if (c.drag_offer) |old| {
                    c.destroyOffer(old);
                    c.drag_offer = null;
                    c.drag_offer_mime_len = 0;
                }
                if (c.drag_callbacks.leave) |f| f(c.drag_callbacks.ctx);
            },
            p.wl_data_device.event.drop => {
                c.dragging_over = false;
                const offer = c.drag_offer orelse return;
                c.drag_offer = null;
                const mlen = c.drag_offer_mime_len;
                c.drag_offer_mime_len = 0;
                if (mlen == 0) {
                    c.destroyOffer(offer);
                    return;
                }
                const mime = c.drag_offer_mime[0..mlen];
                if (c.drag_source != null) {
                    if ((client.Proxy{ .display = c.conn, .id = offer }).request(p.wl_data_offer.request.finish)) |m0| {
                        var m = m0;
                        m.end();
                    } else |_| {}
                    c.destroyOffer(offer);
                    c.conn.flush() catch {};
                    c.recordDrop(c.drag_pos, c.drag_data, mime, c.drag_negotiated_action);
                    return;
                }
                c.cancelDrop();
                var fds: [2]linux.fd_t = undefined;
                if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
                    c.destroyOffer(offer);
                    return;
                }
                const flags = linux.fcntl(fds[0], linux.F.GETFL, 0);
                _ = linux.fcntl(fds[0], linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
                var m = (client.Proxy{ .display = c.conn, .id = offer }).request(p.wl_data_offer.request.receive) catch {
                    _ = linux.close(fds[0]);
                    _ = linux.close(fds[1]);
                    c.destroyOffer(offer);
                    return;
                };
                m.string(mime).fd(fds[1]).end();
                c.conn.flush() catch {};
                c.pending_drop = .{
                    .fd = fds[0],
                    .offer = offer,
                    .pos = c.drag_pos,
                    .action = c.drag_negotiated_action,
                    .mime = c.drag_offer_mime,
                    .mime_len = mlen,
                    .deadline_ms = nowMs(c.io) + paste_timeout_ms,
                };
            },
            p.wl_data_device.event.selection => {
                const id = r.uint() catch return;
                if (c.offer) |old| if (old != id) c.destroyOffer(old);
                c.offer = if (id == 0) null else id;
                c.offer_mime = if (id != 0 and c.incoming == id) c.incoming_mime else null;
                if (c.incoming == id) c.incoming = null;
            },
            else => {},
        }
    }

    fn offerEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_offer.event.offer => {
                if (c.incoming != id) return;
                const mime = (r.string() catch return) orelse return;
                if (c.incoming_first_mime_len == 0 and mime.len > 0) {
                    const n = @min(mime.len, c.incoming_first_mime.len);
                    @memcpy(c.incoming_first_mime[0..n], mime[0..n]);
                    c.incoming_first_mime_len = n;
                }
                for (mime_types, 0..) |t, i| if (std.mem.eql(u8, t, mime)) {
                    if (c.incoming_mime == null or i < c.incoming_mime.?) c.incoming_mime = i;
                };
            },
            p.wl_data_offer.event.source_actions => {
                const actions = r.uint() catch return;
                if (c.incoming == id) c.incoming_source_actions = actions else if (c.drag_offer == id) c.drag_source_actions = actions;
            },
            p.wl_data_offer.event.action => {
                const action = r.uint() catch return;
                if (c.drag_offer == id) c.drag_negotiated_action = action;
            },
            else => {},
        }
    }

    fn sourceEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_data_source.event.send) {
            const fd = r.fd() catch return;
            defer _ = linux.close(fd);
            _ = r.string() catch return;
            const source = c.source orelse return;
            if (source.id != id) return;
            c.writeAll(fd, c.text);
            return;
        }
        const source = c.source orelse return;
        if (source.id != id) return;
        switch (opcode) {
            p.wl_data_source.event.cancelled => c.dropSource(),
            else => {},
        }
    }

    fn dragSourceEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_data_source.event.send) {
            const fd = r.fd() catch return;
            defer _ = linux.close(fd);
            _ = r.string() catch return;
            const source = c.drag_source orelse return;
            if (source.id != id) return;
            c.writeAll(fd, c.drag_data);
            return;
        }
        const source = c.drag_source orelse return;
        if (source.id != id) return;
        switch (opcode) {
            p.wl_data_source.event.target => {
                const mime = r.string() catch return;
                c.drag_accepted = mime != null;
            },
            p.wl_data_source.event.dnd_drop_performed => {
                c.drag_dropped = true;
            },
            p.wl_data_source.event.dnd_finished => {
                c.drag_finished = true;
                c.dropDragSource();
            },
            p.wl_data_source.event.action => {
                c.drag_action = r.uint() catch 0;
            },
            p.wl_data_source.event.cancelled => {
                c.drag_cancelled = true;
                c.dropDragSource();
            },
            else => {},
        }
    }

    /// Writes `data` to a client that pasted it (waiting through `io`, for
    /// up to `paste_timeout_ms`).
    fn writeAll(c: *Clipboard, fd: linux.fd_t, data: []const u8) void {
        const deadline = std.Io.Clock.Timestamp.fromNow(c.io, .{ .raw = .fromMilliseconds(paste_timeout_ms), .clock = .awake });
        var at: usize = 0;
        while (at < data.len) {
            const chunk = [_][]const u8{data[at..]};
            const result = c.io.operateTimeout(.{ .file_write_streaming = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } }, .data = &chunk } }, .{ .deadline = deadline }) catch return;
            at += result.file_write_streaming catch return;
        }
    }
};
