//! What the toolkit asks of the operating system, the same on each it
//! runs on: files, clocks, sleeping, and a `Wake` (an fd one thread makes
//! readable to wake another's event loop). On Linux by its system calls
//! (no C library needed); elsewhere (macOS) by the C library.

const std = @import("std");
const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;
const linux = std.os.linux;
const c = std.c;

pub const fd_t = if (is_linux) linux.fd_t else c.fd_t;

pub const Error = error{ Failed, WouldBlock };

pub fn close(fd: fd_t) void {
    _ = if (is_linux) linux.close(fd) else c.close(fd);
}

/// Reads what there is (0 at the end); `WouldBlock` if nothing is there
/// yet on a non-blocking fd.
pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        if (is_linux) {
            const rc = linux.read(fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.Failed,
            }
        } else {
            const rc = c.read(fd, buf.ptr, buf.len);
            if (rc >= 0) return @intCast(rc);
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.Failed,
            }
        }
    }
}

pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    while (true) {
        if (is_linux) {
            const rc = linux.write(fd, bytes.ptr, bytes.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.Failed,
            }
        } else {
            const rc = c.write(fd, bytes.ptr, bytes.len);
            if (rc >= 0) return @intCast(rc);
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.Failed,
            }
        }
    }
}

pub fn dup(fd: fd_t) ?fd_t {
    if (is_linux) {
        const rc = linux.dup(fd);
        if (linux.errno(rc) != .SUCCESS) return null;
        return @intCast(rc);
    }
    const rc = c.dup(fd);
    return if (rc < 0) null else rc;
}

/// Opens a file to read (null if it cannot be).
pub fn openRead(path: [*:0]const u8) ?fd_t {
    if (is_linux) {
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        return @intCast(rc);
    }
    const rc = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    return if (rc < 0) null else rc;
}

/// A file's bytes (at most `max`), the caller's; null if it cannot be
/// read.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null;
    const fd = openRead(z.ptr) orelse return null;
    defer close(fd);
    var out: std.ArrayList(u8) = .empty;
    while (out.items.len < max) {
        out.ensureUnusedCapacity(gpa, 64 << 10) catch {
            out.deinit(gpa);
            return null;
        };
        const room = out.unusedCapacitySlice();
        const n = read(fd, room[0..@min(room.len, max - out.items.len)]) catch {
            out.deinit(gpa);
            return null;
        };
        if (n == 0) break;
        out.items.len += n;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Replaces a file with `bytes` (false if it cannot be written).
pub fn writeFile(path: [*:0]const u8, bytes: []const u8) bool {
    unlink(path);
    const fd: fd_t = if (is_linux) blk: {
        const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return false;
        break :blk @intCast(rc);
    } else blk: {
        const rc = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        if (rc < 0) return false;
        break :blk rc;
    };
    defer close(fd);
    var at: usize = 0;
    while (at < bytes.len) at += write(fd, bytes[at..]) catch return false;
    return true;
}

pub fn unlink(path: [*:0]const u8) void {
    _ = if (is_linux) linux.unlink(path) else c.unlink(path);
}

pub fn mkdir(path: [*:0]const u8, mode: u32) void {
    _ = if (is_linux) linux.mkdir(path, mode) else c.mkdir(path, @intCast(mode));
}

/// What identifies a file's contents as they are now (its device, inode
/// and when it was changed), to tell when it changes; null if there is no
/// such file.
pub fn fileStamp(path: [*:0]const u8) ?[4]u64 {
    if (is_linux) {
        var stx: linux.Statx = undefined;
        const mask: linux.STATX = .{ .INO = true, .MTIME = true };
        if (linux.errno(linux.statx(linux.AT.FDCWD, path, 0, mask, &stx)) != .SUCCESS) return null;
        return .{ @as(u64, stx.dev_major) << 32 | stx.dev_minor, stx.ino, @bitCast(stx.mtime.sec), stx.mtime.nsec };
    }
    var st: c.Stat = undefined;
    if (c.stat(path, &st) != 0) return null;
    const m = st.mtime();
    return .{ @bitCast(@as(i64, st.dev)), @intCast(st.ino), @bitCast(@as(i64, m.sec)), @intCast(m.nsec) };
}

pub fn getpid() i32 {
    return if (is_linux) linux.getpid() else c.getpid();
}

/// Nanoseconds on a clock that only goes forward.
pub fn monotonicNs() u64 {
    return clockNs(if (is_linux) .MONOTONIC else .MONOTONIC);
}

/// Seconds since 1970 (UTC), with their fraction.
pub fn wallSeconds() f64 {
    return @as(f64, @floatFromInt(clockNs(.REALTIME))) / std.time.ns_per_s;
}

fn clockNs(comptime clock: anytype) u64 {
    if (is_linux) {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(clock, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleepNs(ns: u64) void {
    if (is_linux) {
        var ts: linux.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
        _ = linux.nanosleep(&ts, null);
    } else {
        var ts: c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
        _ = c.nanosleep(&ts, null);
    }
}

/// Waits up to `timeout_ms` (-1: as long as it takes) for `fd` to be
/// readable; whether it is.
pub fn waitReadable(fd: fd_t, timeout_ms: i32) bool {
    if (is_linux) {
        var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        return linux.poll(&p, 1, timeout_ms) == 1;
    }
    var p = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    return c.poll(&p, 1, timeout_ms) == 1;
}

/// An fd that one thread makes readable (`signal`) to wake another that
/// waits on it (`fd`), until it is taken (`drain`): an eventfd on Linux, a
/// pipe elsewhere.
pub const Wake = struct {
    read_fd: fd_t,
    write_fd: fd_t,

    pub fn create() Error!Wake {
        if (is_linux) {
            const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return error.Failed;
            const efd: fd_t = @intCast(rc);
            return .{ .read_fd = efd, .write_fd = efd };
        }
        var fds: [2]fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.Failed;
        for (fds) |pfd| {
            const flags = c.fcntl(pfd, c.F.GETFL);
            _ = c.fcntl(pfd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
            _ = c.fcntl(pfd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        }
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(w: Wake) void {
        close(w.read_fd);
        if (w.write_fd != w.read_fd) close(w.write_fd);
    }

    /// The fd to wait on.
    pub fn fd(w: Wake) fd_t {
        return w.read_fd;
    }

    /// Makes it readable (from any thread).
    pub fn signal(w: Wake) void {
        const one: u64 = 1;
        _ = write(w.write_fd, if (is_linux) std.mem.asBytes(&one) else std.mem.asBytes(&one)[0..1]) catch {};
    }

    /// Takes its wakes; true if there were any.
    pub fn drain(w: Wake) bool {
        var buf: [64]u8 = undefined;
        var any = false;
        while (true) {
            const n = read(w.read_fd, &buf) catch break;
            if (n == 0) break;
            any = true;
            if (is_linux) break;
        }
        return any;
    }
};

test "a wake wakes, and files are read and written" {
    const w = try Wake.create();
    defer w.deinit();
    try std.testing.expect(!w.drain());
    w.signal();
    w.signal();
    try std.testing.expect(waitReadable(w.fd(), 0));
    try std.testing.expect(w.drain());
    try std.testing.expect(!w.drain());

    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "/tmp/facet-sys-test-{d}", .{getpid()}, 0);
    defer unlink(path);
    try std.testing.expect(fileStamp(path) == null);
    try std.testing.expect(writeFile(path, "hello"));
    const bytes = readFile(std.testing.allocator, path, 1 << 20).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
    try std.testing.expect(fileStamp(path) != null);
    try std.testing.expect(monotonicNs() > 0 and wallSeconds() > 1.6e9);
}
