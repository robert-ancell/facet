//! What the toolkit asks of the operating system that `std.Io` has no
//! equivalent of: a `Wake`, an fd that any thread (or a signal handler,
//! or a task on another `Io`) makes readable without blocking or
//! allocating, to wake the UI's event loop; and, for the render thread
//! (which runs outside the app's `Io`), waiting for one (`waitReadable`).
//! Everything else (files, sockets, clocks, waiting) is done through the
//! app's `std.Io`.
//!
//! On Linux by its system calls (no C library needed); elsewhere (macOS)
//! by the C library.

const std = @import("std");
const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;
const linux = std.os.linux;
const c = std.c;

pub const fd_t = if (is_linux) linux.fd_t else c.fd_t;

pub const Error = error{Failed};

fn close(fd: fd_t) void {
    _ = if (is_linux) linux.close(fd) else c.close(fd);
}

/// Waits (on a thread of facet's own, outside the app's `Io`) up to
/// `timeout_ms` (-1: as long as it takes) for `fd` to be readable; whether
/// it is.
pub fn waitReadable(fd: fd_t, timeout_ms: i32) bool {
    if (is_linux) {
        var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        return linux.poll(&p, 1, timeout_ms) == 1;
    }
    var p = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    return c.poll(&p, 1, timeout_ms) == 1;
}

/// An fd that one thread makes readable (`signal`) to wake another that
/// waits on it (`fd`, read through `std.Io` as a window `Source`), until
/// it is taken (`drain`): an eventfd on Linux, a pipe elsewhere. It is
/// non-blocking.
pub const Wake = struct {
    read_fd: fd_t,
    write_fd: fd_t,
    /// Where a read of it through `std.Io` goes (and the slices given to
    /// that read): its value does not matter.
    scratch: [64]u8 = undefined,
    scratch_vec: [1][]u8 = undefined,

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

    pub fn deinit(w: *const Wake) void {
        close(w.read_fd);
        if (w.write_fd != w.read_fd) close(w.write_fd);
    }

    /// The fd to wait on.
    pub fn fd(w: *const Wake) fd_t {
        return w.read_fd;
    }

    /// Makes it readable (from any thread).
    pub fn signal(w: *const Wake) void {
        const one: u64 = 1;
        const bytes = if (is_linux) std.mem.asBytes(&one) else std.mem.asBytes(&one)[0..1];
        _ = if (is_linux) linux.write(w.write_fd, bytes.ptr, bytes.len) else c.write(w.write_fd, bytes.ptr, bytes.len);
    }

    /// Takes its wakes, without waiting; true if there were any.
    pub fn drain(w: *Wake) bool {
        var any = false;
        while (true) {
            const n: isize = if (is_linux) blk: {
                const rc = linux.read(w.read_fd, &w.scratch, w.scratch.len);
                break :blk if (linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
            } else c.read(w.read_fd, &w.scratch, w.scratch.len);
            if (n <= 0) break;
            any = true;
            if (is_linux) break;
        }
        return any;
    }

    /// The read that waits for it, through `std.Io` (into `scratch`).
    pub fn readOperation(w: *Wake) std.Io.Operation {
        w.scratch_vec = .{&w.scratch};
        return .{ .file_read_streaming = .{
            .file = .{ .handle = w.read_fd, .flags = .{ .nonblocking = true } },
            .data = &w.scratch_vec,
        } };
    }
};

test "a wake wakes, and is taken" {
    var w = try Wake.create();
    defer w.deinit();
    try std.testing.expect(!w.drain());
    w.signal();
    w.signal();
    try std.testing.expect(w.drain());
    try std.testing.expect(!w.drain());

    // Waited for through `std.Io`.
    const io = std.testing.io;
    w.signal();
    const result = try io.operateTimeout(w.readOperation(), .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try std.testing.expect(try result.file_read_streaming > 0);
    try std.testing.expect(!w.drain());
}
