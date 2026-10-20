//! The Wayland wire format over a Unix socket, for both clients and
//! servers.
//!
//! A message is a header (the object ID, then the size in bytes << 16 |
//! the opcode) followed by 32-bit aligned arguments: integers, 24.8 fixed
//! point numbers, strings and arrays (a length, then the bytes padded to 4),
//! and object IDs. File descriptors travel separately, as SCM_RIGHTS
//! ancillary data, in the order their messages use them.
//!
//! Reference: https://wayland.freedesktop.org/docs/html/ch04.html

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ Closed, WouldBlock, ProtocolError, BufferFull, TooManyFds, SystemError };

pub const max_message_size = 4096;
const max_fds_per_message = 28;

pub const Message = struct {
    object: u32,
    opcode: u16,
    /// The arguments (without the header).
    data: []const u8,
};

/// A connection's buffered input and output, including file descriptors.
pub const Connection = struct {
    fd: linux.fd_t,
    in: [4 * max_message_size]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    in_fds: [64]linux.fd_t = undefined,
    in_fds_start: usize = 0,
    in_fds_end: usize = 0,
    out: [4 * max_message_size]u8 = undefined,
    out_len: usize = 0,
    out_fds: [max_fds_per_message]linux.fd_t = undefined,
    out_fds_len: usize = 0,

    pub fn init(fd: linux.fd_t) Connection {
        return .{ .fd = fd };
    }

    /// Closes the socket and any file descriptors received but not taken.
    pub fn deinit(c: *Connection) void {
        while (c.takeFd()) |fd| _ = linux.close(fd);
        for (c.out_fds[0..c.out_fds_len]) |fd| _ = linux.close(fd);
        _ = linux.close(c.fd);
    }

    /// Reads what the socket has without blocking. Returns the number of
    /// bytes read (0 with error.WouldBlock if there was nothing).
    pub fn read(c: *Connection) Error!usize {
        // Keep the unprocessed bytes and file descriptors at the front.
        if (c.in_start > 0) {
            std.mem.copyForwards(u8, &c.in, c.in[c.in_start..c.in_end]);
            c.in_end -= c.in_start;
            c.in_start = 0;
        }
        if (c.in_fds_start > 0) {
            std.mem.copyForwards(linux.fd_t, &c.in_fds, c.in_fds[c.in_fds_start..c.in_fds_end]);
            c.in_fds_end -= c.in_fds_start;
            c.in_fds_start = 0;
        }
        if (c.in_end == c.in.len) return error.BufferFull;
        var iov = [_]std.posix.iovec{.{ .base = c.in[c.in_end..].ptr, .len = c.in.len - c.in_end }};
        var control: [cmsgSpace(max_fds_per_message)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var msg: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(c.fd, &msg, linux.MSG.DONTWAIT | linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return error.WouldBlock,
            .INTR => return 0,
            .CONNRESET, .PIPE => return error.Closed,
            else => return error.SystemError,
        }
        // File descriptors.
        var at: usize = 0;
        while (at + @sizeOf(linux.cmsghdr) <= msg.controllen) {
            const hdr: *const linux.cmsghdr = @ptrCast(@alignCast(&control[at]));
            if (hdr.len < @sizeOf(linux.cmsghdr)) break;
            if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
                const data = control[at + cmsgAlign(@sizeOf(linux.cmsghdr)) .. at + hdr.len];
                var i: usize = 0;
                while (i + 4 <= data.len) : (i += 4) {
                    const fd = std.mem.readInt(i32, data[i..][0..4], .little);
                    if (c.in_fds_end == c.in_fds.len) {
                        _ = linux.close(fd);
                        continue;
                    }
                    c.in_fds[c.in_fds_end] = fd;
                    c.in_fds_end += 1;
                }
            }
            at += cmsgAlign(hdr.len);
        }
        if (rc == 0) return error.Closed;
        c.in_end += rc;
        return rc;
    }

    /// The next complete message, if one has arrived.
    pub fn next(c: *Connection) Error!?Message {
        const avail = c.in[c.in_start..c.in_end];
        if (avail.len < 8) return null;
        const object = std.mem.readInt(u32, avail[0..4], .little);
        const word = std.mem.readInt(u32, avail[4..8], .little);
        const size: usize = word >> 16;
        if (size < 8 or size % 4 != 0) return error.ProtocolError;
        if (avail.len < size) {
            if (size > c.in.len) return error.ProtocolError;
            return null;
        }
        c.in_start += size;
        return .{ .object = object, .opcode = @truncate(word), .data = avail[8..size] };
    }

    /// Takes the next received file descriptor.
    pub fn takeFd(c: *Connection) ?linux.fd_t {
        if (c.in_fds_start == c.in_fds_end) return null;
        const fd = c.in_fds[c.in_fds_start];
        c.in_fds_start += 1;
        return fd;
    }

    /// Starts a message; finish it with `Builder.end`.
    pub fn begin(c: *Connection, object: u32, opcode: u16) Error!Builder {
        // Room for a whole message, and for any file descriptor it carries.
        if (c.out.len - c.out_len < max_message_size or c.out_fds_len + 4 > c.out_fds.len) try c.flush();
        if (c.out.len - c.out_len < max_message_size) return error.BufferFull;
        const start = c.out_len;
        c.out_len += 8;
        std.mem.writeInt(u32, c.out[start..][0..4], object, .little);
        return .{ .c = c, .start = start, .opcode = opcode };
    }

    /// Sends everything buffered, waiting for the socket if it is full.
    pub fn flush(c: *Connection) Error!void {
        while (c.out_len > 0 or c.out_fds_len > 0) {
            const iov = [_]std.posix.iovec_const{.{ .base = &c.out, .len = c.out_len }};
            var control: [cmsgSpace(max_fds_per_message)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            var control_len: usize = 0;
            if (c.out_fds_len > 0) {
                const hdr: *linux.cmsghdr = @ptrCast(&control);
                hdr.* = .{ .len = cmsgAlign(@sizeOf(linux.cmsghdr)) + c.out_fds_len * 4, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                for (c.out_fds[0..c.out_fds_len], 0..) |fd, i|
                    std.mem.writeInt(i32, control[cmsgAlign(@sizeOf(linux.cmsghdr)) + i * 4 ..][0..4], fd, .little);
                control_len = cmsgSpace(c.out_fds_len);
            }
            const msg: linux.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = 1,
                .control = if (control_len > 0) &control else null,
                .controllen = control_len,
                .flags = 0,
            };
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => {
                    var fds = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&fds, 1, 1000);
                    continue;
                },
                .PIPE, .CONNRESET => return error.Closed,
                else => return error.SystemError,
            }
            // The kernel has duplicated the descriptors we sent.
            for (c.out_fds[0..c.out_fds_len]) |fd| _ = linux.close(fd);
            c.out_fds_len = 0;
            std.mem.copyForwards(u8, &c.out, c.out[rc..c.out_len]);
            c.out_len -= rc;
        }
    }
};

fn cmsgAlign(n: usize) usize {
    return std.mem.alignForward(usize, n, @sizeOf(usize));
}

fn cmsgSpace(fds: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(fds * 4);
}

/// Writes one message's arguments.
pub const Builder = struct {
    c: *Connection,
    start: usize,
    opcode: u16,

    fn word(b: *Builder, v: u32) void {
        std.mem.writeInt(u32, b.c.out[b.c.out_len..][0..4], v, .little);
        b.c.out_len += 4;
    }

    pub fn uint(b: *Builder, v: u32) *Builder {
        b.word(v);
        return b;
    }

    pub fn int(b: *Builder, v: i32) *Builder {
        b.word(@bitCast(v));
        return b;
    }

    pub fn fixed(b: *Builder, v: f64) *Builder {
        b.word(@bitCast(@as(i32, @intFromFloat(v * 256))));
        return b;
    }

    /// A string (null writes a null string).
    pub fn string(b: *Builder, s: ?[]const u8) *Builder {
        const str = s orelse {
            b.word(0);
            return b;
        };
        b.word(@intCast(str.len + 1));
        @memcpy(b.c.out[b.c.out_len..][0..str.len], str);
        const padded = std.mem.alignForward(usize, str.len + 1, 4);
        @memset(b.c.out[b.c.out_len + str.len ..][0 .. padded - str.len], 0);
        b.c.out_len += padded;
        return b;
    }

    pub fn array(b: *Builder, bytes: []const u8) *Builder {
        b.word(@intCast(bytes.len));
        @memcpy(b.c.out[b.c.out_len..][0..bytes.len], bytes);
        const padded = std.mem.alignForward(usize, bytes.len, 4);
        @memset(b.c.out[b.c.out_len + bytes.len ..][0 .. padded - bytes.len], 0);
        b.c.out_len += padded;
        return b;
    }

    /// Attaches a file descriptor, which is closed once it has been sent.
    /// (`begin` leaves room for a few per message.)
    pub fn fd(b: *Builder, f: linux.fd_t) *Builder {
        b.c.out_fds[b.c.out_fds_len] = f;
        b.c.out_fds_len += 1;
        return b;
    }

    pub fn end(b: *Builder) void {
        const size: u32 = @intCast(b.c.out_len - b.start);
        std.mem.writeInt(u32, b.c.out[b.start + 4 ..][0..4], size << 16 | b.opcode, .little);
    }
};

/// Reads one message's arguments in order.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    c: *Connection,

    pub fn init(c: *Connection, m: Message) Reader {
        return .{ .data = m.data, .c = c };
    }

    pub fn uint(r: *Reader) Error!u32 {
        if (r.pos + 4 > r.data.len) return error.ProtocolError;
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    pub fn int(r: *Reader) Error!i32 {
        return @bitCast(try r.uint());
    }

    pub fn fixed(r: *Reader) Error!f64 {
        return @as(f64, @floatFromInt(try r.int())) / 256;
    }

    /// A string without its terminating NUL, or null for a null string.
    pub fn string(r: *Reader) Error!?[]const u8 {
        const len = try r.uint();
        if (len == 0) return null;
        const padded = std.mem.alignForward(usize, len, 4);
        if (r.pos + padded > r.data.len) return error.ProtocolError;
        const s = r.data[r.pos..][0 .. len - 1];
        if (r.data[r.pos + len - 1] != 0) return error.ProtocolError;
        r.pos += padded;
        return s;
    }

    pub fn array(r: *Reader) Error![]const u8 {
        const len = try r.uint();
        const padded = std.mem.alignForward(usize, len, 4);
        if (r.pos + padded > r.data.len) return error.ProtocolError;
        const a = r.data[r.pos..][0..len];
        r.pos += padded;
        return a;
    }

    pub fn fd(r: *Reader) Error!linux.fd_t {
        return r.c.takeFd() orelse error.ProtocolError;
    }
};

const testing = std.testing;

fn socketPair() ![2]linux.fd_t {
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.SystemError;
    return fds;
}

test "messages and file descriptors round trip" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const fds = try socketPair();
    const a = try testing.allocator.create(Connection);
    defer testing.allocator.destroy(a);
    a.* = .init(fds[0]);
    defer a.deinit();
    const b = try testing.allocator.create(Connection);
    defer testing.allocator.destroy(b);
    b.* = .init(fds[1]);
    defer b.deinit();

    var pipe: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe(&pipe));
    defer _ = linux.close(pipe[0]);

    var m = try a.begin(7, 3);
    m.uint(42).int(-5).fixed(1.5).string("hello").string(null).array(&.{ 1, 2, 3 }).fd(pipe[1]).end();
    var m2 = try a.begin(8, 0);
    m2.end();
    try a.flush();

    _ = try b.read();
    const msg = (try b.next()).?;
    try testing.expectEqual(@as(u32, 7), msg.object);
    try testing.expectEqual(@as(u16, 3), msg.opcode);
    var r = Reader.init(b, msg);
    try testing.expectEqual(@as(u32, 42), try r.uint());
    try testing.expectEqual(@as(i32, -5), try r.int());
    try testing.expectEqual(@as(f64, 1.5), try r.fixed());
    try testing.expectEqualStrings("hello", (try r.string()).?);
    try testing.expectEqual(@as(?[]const u8, null), try r.string());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, try r.array());
    const got = try r.fd();
    // The received descriptor is the write end of the pipe.
    try testing.expectEqual(@as(usize, 1), linux.write(got, "x", 1));
    _ = linux.close(got);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(pipe[0], &byte, 1));
    try testing.expectError(error.ProtocolError, r.uint());

    const empty = (try b.next()).?;
    try testing.expectEqual(@as(u32, 8), empty.object);
    try testing.expectEqual(@as(usize, 0), empty.data.len);
    try testing.expect(try b.next() == null);
    try testing.expectError(error.WouldBlock, b.read());
}

test "partial messages wait for the rest" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const fds = try socketPair();
    var b: Connection = .init(fds[1]);
    defer b.deinit();
    defer _ = linux.close(fds[0]);
    // A 12-byte message sent in two parts.
    _ = linux.write(fds[0], &[_]u8{ 1, 0, 0, 0, 2, 0, 12, 0 }, 8);
    _ = try b.read();
    try testing.expect(try b.next() == null);
    _ = linux.write(fds[0], &[_]u8{ 9, 0, 0, 0 }, 4);
    _ = try b.read();
    const m = (try b.next()).?;
    try testing.expectEqual(@as(u16, 2), m.opcode);
    try testing.expectEqual(@as(usize, 4), m.data.len);
}

test "bad sizes are protocol errors, and a closed peer is reported" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const fds = try socketPair();
    var b: Connection = .init(fds[1]);
    defer b.deinit();
    _ = linux.write(fds[0], &[_]u8{ 1, 0, 0, 0, 0, 0, 6, 0 }, 8);
    _ = try b.read();
    try testing.expectError(error.ProtocolError, b.next());
    _ = linux.close(fds[0]);
    try testing.expectError(error.Closed, b.read());
}
