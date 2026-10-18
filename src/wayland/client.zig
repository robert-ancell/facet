//! A small Wayland client library: connecting, sending requests, and
//! dispatching events to listeners registered per object.
//!
//! Object IDs are allocated upwards and not reused; a client would need
//! billions of objects to run out. Everything runs on the caller's thread:
//! `dispatch` reads and handles events until something arrives, and
//! `roundtrip` waits until the server has handled every request sent so far.

const std = @import("std");
const linux = std.os.linux;
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");

pub const Error = wire.Error || error{ ConnectFailed, NoRuntimeDir, ServerError, OutOfMemory };

/// Called for each event on an object.
pub const Listener = struct {
    ptr: ?*anyopaque,
    handler: *const fn (ptr: ?*anyopaque, d: *Display, object: u32, opcode: u16, r: *wire.Reader) void,
};

/// An object on the connection.
pub const Proxy = struct {
    display: *Display = undefined,
    id: u32 = 0,

    /// Starts a request on this object.
    pub fn request(p: Proxy, opcode: u16) Error!wire.Builder {
        if (p.id == 0) return error.Closed;
        return p.display.conn.begin(p.id, opcode);
    }
};

pub const Display = struct {
    gpa: std.mem.Allocator,
    conn: wire.Connection,
    next_id: u32 = 2,
    listeners: std.AutoHashMapUnmanaged(u32, Listener) = .empty,
    /// Set when the server reports a fatal error.
    failed: bool = false,
    error_object: u32 = 0,
    error_code: u32 = 0,
    error_buf: [128]u8 = undefined,
    error_len: usize = 0,

    /// The server's error message, if it sent one.
    pub fn errorMessage(d: *const Display) []const u8 {
        return d.error_buf[0..d.error_len];
    }

    /// Connects to `path`.
    pub fn connect(gpa: std.mem.Allocator, path: []const u8) Error!*Display {
        const fd: linux.fd_t = @intCast(sysCheck(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return error.ConnectFailed);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.ConnectFailed;
        @memcpy(addr.path[0..path.len], path);
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
            _ = linux.close(fd);
            return error.ConnectFailed;
        }
        return fromFd(gpa, fd);
    }

    /// Connects to the compositor named in `environ` ($WAYLAND_DISPLAY in
    /// $XDG_RUNTIME_DIR).
    pub fn connectEnviron(gpa: std.mem.Allocator, environ: std.process.Environ) Error!*Display {
        var buf: [128]u8 = undefined;
        return connect(gpa, try environSocketPath(&buf, environ));
    }

    /// Uses an already connected socket.
    pub fn fromFd(gpa: std.mem.Allocator, fd: linux.fd_t) Error!*Display {
        const d = try gpa.create(Display);
        d.* = .{ .gpa = gpa, .conn = .init(fd) };
        try d.listeners.put(gpa, protocol.wl_display.id, .{ .ptr = null, .handler = displayEvent });
        return d;
    }

    pub fn disconnect(d: *Display) void {
        d.conn.deinit();
        d.listeners.deinit(d.gpa);
        d.gpa.destroy(d);
    }

    pub fn proxy(d: *Display) Proxy {
        return .{ .display = d, .id = protocol.wl_display.id };
    }

    /// A new object ID, with an optional listener for its events.
    pub fn newObject(d: *Display, listener: ?Listener) Error!Proxy {
        const id = d.next_id;
        d.next_id += 1;
        if (listener) |l| try d.listeners.put(d.gpa, id, l);
        return .{ .display = d, .id = id };
    }

    pub fn setListener(d: *Display, id: u32, listener: Listener) Error!void {
        try d.listeners.put(d.gpa, id, listener);
    }

    /// Stops delivering an object's events (after it has been destroyed).
    pub fn forget(d: *Display, id: u32) void {
        _ = d.listeners.remove(id);
    }

    pub fn flush(d: *Display) Error!void {
        return d.conn.flush();
    }

    /// Handles the events already received, without waiting.
    pub fn dispatchPending(d: *Display) Error!usize {
        var n: usize = 0;
        while (true) {
            while (try d.conn.next()) |m| {
                var r = wire.Reader.init(&d.conn, m);
                if (d.listeners.get(m.object)) |l| l.handler(l.ptr, d, m.object, m.opcode, &r);
                n += 1;
                if (d.failed) return error.ServerError;
            }
            _ = d.conn.read() catch |e| switch (e) {
                error.WouldBlock => return n,
                else => return e,
            };
        }
    }

    /// Flushes requests, then handles events, waiting for at least one.
    pub fn dispatch(d: *Display) Error!void {
        try d.flush();
        while (true) {
            if (try d.dispatchPending() > 0) return;
            var fds = [_]linux.pollfd{.{ .fd = d.conn.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, -1);
        }
    }

    /// Flushes requests, then handles events, waiting up to `timeout_ms`
    /// for one (returning sooner if one arrives).
    pub fn dispatchTimeout(d: *Display, timeout_ms: i32) Error!void {
        try d.flush();
        if (try d.dispatchPending() > 0) return;
        var fds = [_]linux.pollfd{.{ .fd = d.conn.fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&fds, 1, timeout_ms);
        _ = try d.dispatchPending();
    }

    /// Waits until the server has processed every request sent so far.
    pub fn roundtrip(d: *Display) Error!void {
        var done = false;
        const cb = try d.newObject(.{ .ptr = &done, .handler = setFlag });
        var m = try d.proxy().request(protocol.wl_display.request.sync);
        m.uint(cb.id).end();
        while (!done) try d.dispatch();
        d.forget(cb.id);
    }

    fn setFlag(ptr: ?*anyopaque, _: *Display, _: u32, _: u16, _: *wire.Reader) void {
        const flag: *bool = @ptrCast(ptr.?);
        flag.* = true;
    }

    fn displayEvent(_: ?*anyopaque, d: *Display, _: u32, opcode: u16, r: *wire.Reader) void {
        switch (opcode) {
            protocol.wl_display.event.@"error" => {
                d.error_object = r.uint() catch 0;
                d.error_code = r.uint() catch 0;
                const message = (r.string() catch null) orelse "";
                d.error_len = @min(message.len, d.error_buf.len);
                @memcpy(d.error_buf[0..d.error_len], message[0..d.error_len]);
                d.failed = true;
            },
            protocol.wl_display.event.delete_id => {
                const id = r.uint() catch return;
                d.forget(id);
            },
            else => {},
        }
    }
};

fn sysCheck(rc: usize) !usize {
    return if (linux.errno(rc) == .SUCCESS) rc else error.SystemError;
}

/// The socket path for $XDG_RUNTIME_DIR and $WAYLAND_DISPLAY: an absolute
/// WAYLAND_DISPLAY is used as is, and otherwise it (default "wayland-0")
/// is in XDG_RUNTIME_DIR.
pub fn socketPath(buf: []u8, runtime_dir: ?[]const u8, wayland_display: ?[]const u8) Error![]const u8 {
    const name = wayland_display orelse "wayland-0";
    if (name.len > 0 and name[0] == '/') return name;
    const dir = runtime_dir orelse return error.NoRuntimeDir;
    return std.mem.print(buf, "{s}/{s}", .{ dir, name }) catch error.NoRuntimeDir;
}

/// The socket path for `environ`'s $XDG_RUNTIME_DIR and $WAYLAND_DISPLAY.
pub fn environSocketPath(buf: []u8, environ: std.process.Environ) Error![]const u8 {
    const Environ = std.process.Environ;
    return socketPath(buf, Environ.getPosix(environ, "XDG_RUNTIME_DIR"), Environ.getPosix(environ, "WAYLAND_DISPLAY"));
}

/// The globals a registry announced.
pub const Globals = struct {
    pub const Global = struct { name: u32, interface: [64]u8, interface_len: usize, version: u32 };
    list: [128]Global = undefined,
    len: usize = 0,

    pub fn find(g: *const Globals, interface: []const u8) ?Global {
        for (g.list[0..g.len]) |gl| if (std.mem.eql(u8, gl.interface[0..gl.interface_len], interface)) return gl;
        return null;
    }

    fn event(ptr: ?*anyopaque, _: *Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const g: *Globals = @ptrCast(@alignCast(ptr.?));
        if (opcode != protocol.wl_registry.event.global or g.len == g.list.len) return;
        const name = r.uint() catch return;
        const interface = (r.string() catch return) orelse return;
        const version = r.uint() catch return;
        if (interface.len > 64) return;
        var entry: Global = .{ .name = name, .interface = undefined, .interface_len = interface.len, .version = version };
        @memcpy(entry.interface[0..interface.len], interface);
        g.list[g.len] = entry;
        g.len += 1;
    }

    /// Gets the registry and waits for its globals. `g` must stay in place
    /// while the registry exists.
    pub fn fetch(g: *Globals, d: *Display) Error!Proxy {
        const registry = try d.newObject(.{ .ptr = g, .handler = event });
        var m = try d.proxy().request(protocol.wl_display.request.get_registry);
        m.uint(registry.id).end();
        try d.roundtrip();
        return registry;
    }

    /// Binds a global, at most at `version`. Returns null if it is missing.
    pub fn bind(g: *const Globals, registry: Proxy, interface: []const u8, version: u32, listener: ?Listener) Error!?Proxy {
        const gl = g.find(interface) orelse return null;
        const p = try registry.display.newObject(listener);
        var m = try registry.request(protocol.wl_registry.request.bind);
        m.uint(gl.name).string(interface).uint(@min(version, gl.version)).uint(p.id).end();
        return p;
    }
};

test "socket paths" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/xdg/wayland-0", try socketPath(&buf, "/tmp/xdg", null));
    try std.testing.expectEqualStrings("/tmp/w", try socketPath(&buf, null, "/tmp/w"));
    try std.testing.expectError(error.NoRuntimeDir, socketPath(&buf, null, "wayland-1"));
    try std.testing.expectError(error.NoRuntimeDir, socketPath(&buf, null, null));
    try std.testing.expectError(error.NoRuntimeDir, environSocketPath(&buf, .empty));
}
