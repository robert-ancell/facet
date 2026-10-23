//! A small D-Bus client: connecting to a bus (a Unix socket, by its
//! address), authenticating (EXTERNAL, as this user), and sending and
//! receiving messages, their bodies written and read in D-Bus's wire
//! format (little-endian). Enough for an app to offer objects on a bus
//! and send signals (as AT-SPI needs), and to call methods.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ ConnectFailed, AuthFailed, Malformed, Closed, Timeout, CallFailed, OutOfMemory, Canceled };

pub const MessageType = enum(u8) { method_call = 1, method_return = 2, @"error" = 3, signal = 4, _ };

/// Flags: no reply is wanted.
pub const no_reply_expected = 1;

// --- Writing ------------------------------------------------------------------

/// Writes values in D-Bus's wire format, each aligned as it must be (from
/// the start of what is written, which is where a message's body starts).
pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Set if memory ran out: what was written is not to be used.
    failed: bool = false,

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.gpa);
    }

    fn bytes(w: *Writer, b: []const u8) void {
        w.buf.appendSlice(w.gpa, b) catch {
            w.failed = true;
        };
    }

    pub fn pad(w: *Writer, n: usize) void {
        while (!w.failed and w.buf.items.len % n != 0) w.bytes(&.{0});
    }

    pub fn byte(w: *Writer, v: u8) void {
        w.bytes(&.{v});
    }

    fn int(w: *Writer, comptime T: type, v: T) void {
        w.pad(@sizeOf(T));
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        w.bytes(&b);
    }

    pub fn boolean(w: *Writer, v: bool) void {
        w.int(u32, @intFromBool(v));
    }
    pub fn int16(w: *Writer, v: i16) void {
        w.int(i16, v);
    }
    pub fn uint16(w: *Writer, v: u16) void {
        w.int(u16, v);
    }
    pub fn int32(w: *Writer, v: i32) void {
        w.int(i32, v);
    }
    pub fn uint32(w: *Writer, v: u32) void {
        w.int(u32, v);
    }
    pub fn int64(w: *Writer, v: i64) void {
        w.int(i64, v);
    }
    pub fn uint64(w: *Writer, v: u64) void {
        w.int(u64, v);
    }
    pub fn double(w: *Writer, v: f64) void {
        w.int(u64, @bitCast(v));
    }

    /// A string (`s`), or an object path (`o`).
    pub fn string(w: *Writer, s: []const u8) void {
        w.uint32(@intCast(s.len));
        w.bytes(s);
        w.byte(0);
    }

    pub const objectPath = string;

    /// A signature (`g`).
    pub fn signature(w: *Writer, s: []const u8) void {
        w.byte(@intCast(s.len));
        w.bytes(s);
        w.byte(0);
    }

    pub const Array = struct { len_at: usize, start: usize };

    /// Starts an array of elements aligned to `elem_align` (8 for structs
    /// and dict entries): its elements follow, then `endArray`.
    pub fn beginArray(w: *Writer, elem_align: usize) Array {
        w.uint32(0);
        const len_at = if (w.failed) 0 else w.buf.items.len - 4;
        w.pad(elem_align);
        return .{ .len_at = len_at, .start = w.buf.items.len };
    }

    pub fn endArray(w: *Writer, a: Array) void {
        if (w.failed) return;
        std.mem.writeInt(u32, w.buf.items[a.len_at..][0..4], @intCast(w.buf.items.len - a.start), .little);
    }

    /// Starts a struct or dict entry (aligned to 8).
    pub fn beginStruct(w: *Writer) void {
        w.pad(8);
    }

    /// A variant's signature: its value follows.
    pub fn variant(w: *Writer, sig: []const u8) void {
        w.signature(sig);
    }
};

// --- Reading -------------------------------------------------------------------

/// Reads values in D-Bus's wire format (from the start of a message's
/// body, or of the message).
pub const Reader = struct {
    data: []const u8,
    at: usize = 0,

    pub fn alignTo(r: *Reader, n: usize) Error!void {
        const to = std.mem.alignForward(usize, r.at, n);
        if (to > r.data.len) return error.Malformed;
        r.at = to;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.data.len - r.at) return error.Malformed;
        r.at += n;
        return r.data[r.at - n .. r.at];
    }

    pub fn byte(r: *Reader) Error!u8 {
        return (try r.take(1))[0];
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        try r.alignTo(@sizeOf(T));
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    pub fn boolean(r: *Reader) Error!bool {
        return try r.int(u32) != 0;
    }
    pub fn int16(r: *Reader) Error!i16 {
        return r.int(i16);
    }
    pub fn uint16(r: *Reader) Error!u16 {
        return r.int(u16);
    }
    pub fn int32(r: *Reader) Error!i32 {
        return r.int(i32);
    }
    pub fn uint32(r: *Reader) Error!u32 {
        return r.int(u32);
    }
    pub fn int64(r: *Reader) Error!i64 {
        return r.int(i64);
    }
    pub fn uint64(r: *Reader) Error!u64 {
        return r.int(u64);
    }
    pub fn double(r: *Reader) Error!f64 {
        return @bitCast(try r.int(u64));
    }

    /// A string or object path.
    pub fn string(r: *Reader) Error![]const u8 {
        const len = try r.uint32();
        const s = try r.take(len);
        if (try r.byte() != 0) return error.Malformed;
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Malformed;
        return s;
    }

    pub fn signature(r: *Reader) Error![]const u8 {
        const len = try r.byte();
        const s = try r.take(len);
        if (try r.byte() != 0) return error.Malformed;
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Malformed;
        return s;
    }

    /// Starts an array of elements aligned to `elem_align`: where it ends.
    pub fn array(r: *Reader, elem_align: usize) Error!usize {
        const len = try r.uint32();
        try r.alignTo(elem_align);
        if (len > r.data.len - r.at) return error.Malformed;
        return r.at + len;
    }

    pub fn beginStruct(r: *Reader) Error!void {
        try r.alignTo(8);
    }

    /// Reads past one value of the complete type `sig` starts with;
    /// returns the rest of `sig`.
    pub fn skip(r: *Reader, sig: []const u8) Error![]const u8 {
        if (sig.len == 0) return error.Malformed;
        switch (sig[0]) {
            'y' => _ = try r.byte(),
            'b', 'i', 'u', 'h' => _ = try r.uint32(),
            'n', 'q' => _ = try r.uint16(),
            'x', 't', 'd' => _ = try r.uint64(),
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                const inner = try r.signature();
                if (inner.len == 0) return error.Malformed;
                const rest = try r.skip(inner);
                if (rest.len != 0) return error.Malformed;
            },
            'a' => {
                const elem = sig[1..];
                const elem_len = try typeLength(elem);
                const end = try r.array(alignOf(elem[0]));
                while (r.at < end) _ = try r.skip(elem[0..elem_len]);
                if (r.at != end) return error.Malformed;
                return elem[elem_len..];
            },
            '(', '{' => {
                try r.beginStruct();
                const len = try typeLength(sig);
                var inner = sig[1 .. len - 1];
                while (inner.len > 0) inner = try r.skip(inner);
                return sig[len..];
            },
            else => return error.Malformed,
        }
        return sig[1..];
    }
};

/// How a value of the type starting `c` is aligned.
pub fn alignOf(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

/// How long the complete type `sig` starts with is.
fn typeLength(sig: []const u8) Error!usize {
    if (sig.len == 0) return error.Malformed;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => return 1,
        'a' => return 1 + try typeLength(sig[1..]),
        '(' => {
            var i: usize = 1;
            while (i < sig.len and sig[i] != ')') i += try typeLength(sig[i..]);
            if (i == 1 or i >= sig.len) return error.Malformed;
            return i + 1;
        },
        '{' => {
            if (sig.len < 4) return error.Malformed;
            switch (sig[1]) {
                'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g' => {},
                else => return error.Malformed,
            }
            const val_len = try typeLength(sig[2..]);
            if (2 + val_len >= sig.len or sig[2 + val_len] != '}') return error.Malformed;
            return 2 + val_len + 1;
        },
        else => return error.Malformed,
    }
}

// --- Messages ------------------------------------------------------------------

/// A message's header: what it is, who it is for, and what it is about.
pub const Header = struct {
    type: MessageType,
    flags: u8 = 0,
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
};

/// A message as received: its header's fields, and its body (slices of
/// its bytes).
pub const Message = struct {
    header: Header,
    body: []const u8,

    pub fn reader(m: *const Message) Reader {
        return .{ .data = m.body };
    }
};

/// The bytes of a message with this header and body (written with
/// `Writer`, starting at its start).
pub fn encode(gpa: std.mem.Allocator, h: Header, body: []const u8) Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.deinit();
    w.byte('l');
    w.byte(@backingInt(h.type));
    w.byte(h.flags);
    w.byte(1);
    w.uint32(@intCast(body.len));
    w.uint32(h.serial);
    const fields = w.beginArray(8);
    const Field = struct { code: u8, sig: []const u8, value: ?[]const u8 = null, number: ?u32 = null };
    const all = [_]Field{
        .{ .code = 1, .sig = "o", .value = h.path },
        .{ .code = 2, .sig = "s", .value = h.interface },
        .{ .code = 3, .sig = "s", .value = h.member },
        .{ .code = 4, .sig = "s", .value = h.error_name },
        .{ .code = 5, .sig = "u", .number = h.reply_serial },
        .{ .code = 6, .sig = "s", .value = h.destination },
        .{ .code = 7, .sig = "s", .value = h.sender },
        .{ .code = 8, .sig = "g", .value = if (h.signature.len > 0) h.signature else null },
    };
    for (all) |f| {
        if (f.value == null and f.number == null) continue;
        w.beginStruct();
        w.byte(f.code);
        w.variant(f.sig);
        if (f.number) |n| w.uint32(n) else if (f.sig[0] == 'g') w.signature(f.value.?) else w.string(f.value.?);
    }
    w.endArray(fields);
    w.pad(8);
    w.bytes(body);
    if (w.failed) return error.OutOfMemory;
    return w.buf.toOwnedSlice(gpa) catch error.OutOfMemory;
}

/// How long the message `data` starts with is, once its fixed header is
/// there (16 bytes); null before.
pub fn messageLength(data: []const u8) Error!?usize {
    if (data.len < 16) return null;
    if (data[0] != 'l') return error.Malformed;
    const body_len = std.mem.readInt(u32, data[4..8], .little);
    const fields_len = std.mem.readInt(u32, data[12..16], .little);
    const total = std.mem.alignForward(u64, 16 + @as(u64, fields_len), 8) + body_len;
    if (total > 128 << 20) return error.Malformed;
    return @intCast(total);
}

/// The message in `data` (all of it), its fields and body slices of it.
pub fn decode(data: []const u8) Error!Message {
    const len = (try messageLength(data)) orelse return error.Malformed;
    if (data.len < len) return error.Malformed;
    var r: Reader = .{ .data = data[0..len] };
    _ = try r.byte();
    const kind: MessageType = @fromBackingInt(@intCast(try r.byte()));
    const flags = try r.byte();
    _ = try r.byte();
    const body_len = try r.uint32();
    var h: Header = .{ .type = kind, .flags = flags, .serial = try r.uint32() };
    const end = try r.array(8);
    while (r.at < end) {
        try r.beginStruct();
        const code = try r.byte();
        const sig = try r.signature();
        if (code == 0) return error.Malformed;
        switch (code) {
            1 => {
                if (!std.mem.eql(u8, sig, "o")) return error.Malformed;
                h.path = try r.string();
            },
            2 => {
                if (!std.mem.eql(u8, sig, "s")) return error.Malformed;
                h.interface = try r.string();
            },
            3 => {
                if (!std.mem.eql(u8, sig, "s")) return error.Malformed;
                h.member = try r.string();
            },
            4 => {
                if (!std.mem.eql(u8, sig, "s")) return error.Malformed;
                h.error_name = try r.string();
            },
            5 => {
                if (!std.mem.eql(u8, sig, "u")) return error.Malformed;
                h.reply_serial = try r.uint32();
            },
            6 => {
                if (!std.mem.eql(u8, sig, "s")) return error.Malformed;
                h.destination = try r.string();
            },
            7 => {
                if (!std.mem.eql(u8, sig, "s")) return error.Malformed;
                h.sender = try r.string();
            },
            8 => {
                if (!std.mem.eql(u8, sig, "g")) return error.Malformed;
                h.signature = try r.signature();
                var s = h.signature;
                while (s.len > 0) s = s[try typeLength(s)..];
            },
            else => {
                const rest = try r.skip(sig);
                if (rest.len != 0) return error.Malformed;
            },
        }
    }
    if (r.at != end) return error.Malformed;
    try r.alignTo(8);
    if (r.at + body_len != len) return error.Malformed;
    return .{ .header = h, .body = data[r.at..len] };
}

// --- Connections ---------------------------------------------------------------

/// A connection to a bus. What would block (connecting, authenticating,
/// waiting for a reply, or for the socket to take more) is done through
/// the `std.Io` it is given; `source` is for an event loop to wait on it
/// with others.
pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    fd: linux.fd_t,
    serial: u32 = 0,
    closed: bool = false,
    /// The name the bus gave it.
    unique_name: []u8 = &.{},
    /// Bytes read, not yet a whole message.
    in: std.ArrayList(u8) = .empty,
    /// Messages read while waiting for a reply, not yet taken.
    queued: std.ArrayList([]u8) = .empty,
    /// What a read through `io` reads into.
    read_buf: [4096]u8 = undefined,
    read_vec: [1][]u8 = undefined,

    /// Connects to the bus at `address` (`unix:path=…` or
    /// `unix:abstract=…`, the first of those listed that it can), and says
    /// hello.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, address: []const u8) Error!*Connection {
        var it = std.mem.splitScalar(u8, address, ';');
        const fd = while (it.next()) |one| {
            if (connectTo(io, one)) |fd| break fd;
        } else return error.ConnectFailed;
        errdefer _ = linux.close(fd);
        try authenticate(io, fd);
        const c = try gpa.create(Connection);
        c.* = .{ .gpa = gpa, .io = io, .fd = fd };
        errdefer gpa.destroy(c);
        // From now on, read without waiting (except for replies).
        _ = linux.fcntl(fd, linux.F.SETFL, linux.SOCK.NONBLOCK);
        const reply = try c.callWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", "", 5000);
        defer gpa.free(reply);
        const m = try decode(reply);
        var r = m.reader();
        c.unique_name = try gpa.dupe(u8, try r.string());
        return c;
    }

    pub fn close(c: *Connection) void {
        _ = linux.close(c.fd);
        c.in.deinit(c.gpa);
        for (c.queued.items) |m| c.gpa.free(m);
        c.queued.deinit(c.gpa);
        c.gpa.free(c.unique_name);
        c.gpa.destroy(c);
    }

    pub fn nextSerial(c: *Connection) u32 {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        return c.serial;
    }

    /// Sends a message's bytes (waiting, through `io`, while the socket is
    /// full).
    pub fn send(c: *Connection, bytes: []const u8) Error!void {
        if (c.closed) return error.Closed;
        var at: usize = 0;
        while (at < bytes.len) {
            const data = [_][]const u8{bytes[at..]};
            const result = c.io.operateTimeout(.{ .file_write_streaming = .{ .file = c.file(), .data = &data } }, seconds(1)) catch |e| return switch (e) {
                error.Timeout => error.Timeout,
                error.Canceled => error.Canceled,
                else => {
                    c.closed = true;
                    return error.Closed;
                },
            };
            const written = result.file_write_streaming catch {
                c.closed = true;
                return error.Closed;
            };
            if (written == 0) {
                c.closed = true;
                return error.Closed;
            }
            at += written;
        }
    }

    fn file(c: *const Connection) std.Io.File {
        return .{ .handle = c.fd, .flags = .{ .nonblocking = true } };
    }

    /// The read that waits for what comes next, through `io`: for an
    /// event loop to wait on it with others (see `window.Source`), giving
    /// `readDone` what it read.
    pub fn readOperation(c: *Connection) ?std.Io.Operation {
        if (c.closed) return null;
        c.read_vec = .{&c.read_buf};
        return .{ .file_read_streaming = .{ .file = c.file(), .data = &c.read_vec } };
    }

    /// Keeps what a `readOperation` read (for `next`).
    pub fn readDone(c: *Connection, result: std.Io.Operation.Result) void {
        const n = result.file_read_streaming catch |err| {
            if (err != error.WouldBlock and err != error.Canceled) c.closed = true;
            return;
        };
        if (n == 0) {
            c.closed = true;
            return;
        }
        c.in.appendSlice(c.gpa, c.read_buf[0..n]) catch {};
    }

    /// Sends a message with this header (its serial set) and body.
    pub fn sendMessage(c: *Connection, h: Header, body: []const u8) Error!u32 {
        var hh = h;
        hh.serial = c.nextSerial();
        const bytes = try encode(c.gpa, hh, body);
        defer c.gpa.free(bytes);
        try c.send(bytes);
        return hh.serial;
    }

    /// Calls a method, and waits up to `timeout_ms` for its reply (the
    /// message's bytes, the caller's to free); an error reply fails.
    pub fn callWait(c: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, sig: []const u8, body: []const u8, timeout_ms: i32) Error![]u8 {
        const serial = try c.sendMessage(.{ .type = .method_call, .serial = 0, .destination = destination, .path = path, .interface = interface, .member = member, .signature = sig }, body);
        const deadline = std.Io.Clock.Timestamp.fromNow(c.io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
        while (true) {
            // What has come, kept aside unless it is the reply.
            while (try c.readOne()) |bytes| {
                const m = decode(bytes) catch {
                    c.gpa.free(bytes);
                    continue;
                };
                if ((m.header.type == .method_return or m.header.type == .@"error") and m.header.reply_serial == serial) {
                    if (m.header.type == .@"error") {
                        c.gpa.free(bytes);
                        return error.CallFailed;
                    }
                    return bytes;
                }
                c.queued.append(c.gpa, bytes) catch c.gpa.free(bytes);
            }
            const op = c.readOperation() orelse return error.Closed;
            const result = c.io.operateTimeout(op, .{ .deadline = deadline }) catch |e| return switch (e) {
                error.Timeout => error.Timeout,
                error.Canceled => error.Canceled,
                else => {
                    c.closed = true;
                    return error.Closed;
                },
            };
            c.readDone(result);
        }
    }

    /// The next message (its bytes, the caller's to free), if one has
    /// come; doesn't wait.
    pub fn next(c: *Connection) Error!?[]u8 {
        if (c.queued.items.len > 0) return c.queued.orderedRemove(0);
        return c.readOne();
    }

    /// Reads what there is, and gives a whole message if there is one.
    fn readOne(c: *Connection) Error!?[]u8 {
        while (true) {
            if (try messageLength(c.in.items)) |len| if (c.in.items.len >= len) {
                const m = try c.gpa.dupe(u8, c.in.items[0..len]);
                std.mem.copyForwards(u8, c.in.items, c.in.items[len..]);
                c.in.shrinkRetainingCapacity(c.in.items.len - len);
                return m;
            };
            if (c.closed) return error.Closed;
            var buf: [4096]u8 = undefined;
            const rc = linux.read(c.fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        c.closed = true;
                        return error.Closed;
                    }
                    try c.in.appendSlice(c.gpa, buf[0..rc]);
                },
                .AGAIN => return null,
                .INTR => {},
                else => {
                    c.closed = true;
                    return error.Closed;
                },
            }
        }
    }
};

fn seconds(n: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } };
}

/// A socket connected (through `io`) to one of an address's
/// (`unix:path=…`, or `unix:abstract=…`).
fn connectTo(io: std.Io, address: []const u8) ?linux.fd_t {
    if (!std.mem.startsWith(u8, address, "unix:")) return null;
    var path_buf: [108]u8 = undefined;
    var path: ?[]const u8 = null;
    var abstract = false;
    var keys = std.mem.splitScalar(u8, address["unix:".len..], ',');
    while (keys.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "abstract")) {
            path = unescape(kv[eq + 1 ..], &path_buf) orelse return null;
            abstract = key[0] == 'a';
        }
    }
    const p = path orelse return null;
    if (!abstract) {
        const addr = std.Io.net.UnixAddress.init(p) catch return null;
        const stream = addr.connect(io) catch return null;
        return stream.socket.handle;
    }
    // An abstract name (a NUL, then the name, its length the address's),
    // connected to here: `std.Io`'s addresses add a NUL to the length,
    // which makes it another name (in Zig 0.17: until
    // https://codeberg.org/ziglang/zig/issues/35919 is fixed, by
    // https://codeberg.org/ziglang/zig/pulls/35920).
    const fd: linux.fd_t = @intCast(blk: {
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        break :blk rc;
    });
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (p.len + 1 >= addr.path.len) {
        _ = linux.close(fd);
        return null;
    }
    @memcpy(addr.path[1..][0..p.len], p);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + p.len);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), len)) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// An address value with its %xx escapes undone.
fn unescape(s: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (n == buf.len) return null;
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        } else buf[n] = s[i];
        n += 1;
    }
    return buf[0..n];
}

/// D-Bus's EXTERNAL authentication, as this user (waiting through `io`,
/// on the socket as it is when connected: blocking).
fn authenticate(io: std.Io, fd: linux.fd_t) Error!void {
    var uid_buf: [16]u8 = undefined;
    const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()}) catch unreachable;
    var line_buf: [64]u8 = undefined;
    var hex_buf: [32]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{uid}) catch unreachable;
    const line = std.fmt.bufPrint(&line_buf, "\x00AUTH EXTERNAL {s}\r\n", .{hex}) catch unreachable;
    try writeAll(io, fd, line);
    // "OK <guid>\r\n".
    var reply: [256]u8 = undefined;
    var n: usize = 0;
    while (!std.mem.endsWith(u8, reply[0..n], "\r\n")) {
        if (n == reply.len) return error.AuthFailed;
        var data = [_][]u8{reply[n..]};
        const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = fd, .data = &data } }, seconds(5)) catch return error.AuthFailed;
        const got = result.net_read catch return error.AuthFailed;
        if (got.data_len == 0) return error.AuthFailed;
        n += got.data_len;
    }
    if (!std.mem.startsWith(u8, reply[0..n], "OK ")) return error.AuthFailed;
    try writeAll(io, fd, "BEGIN\r\n");
}

fn writeAll(io: std.Io, fd: linux.fd_t, bytes: []const u8) Error!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const data = [_][]const u8{bytes[at..]};
        const result = io.operate(.{ .net_write = .{ .socket_handle = fd, .data = &data } }) catch return error.AuthFailed;
        at += result.net_write catch return error.AuthFailed;
    }
}

// --- Tests -----------------------------------------------------------------------

const testing = std.testing;

test "values are written and read back, aligned as D-Bus has them" {
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    w.byte(7);
    w.uint32(0xdeadbeef);
    w.string("héllo");
    const a = w.beginArray(8);
    for (0..3) |i| {
        w.beginStruct();
        w.string("x");
        w.objectPath("/a/b");
        w.int32(@intCast(i));
    }
    w.endArray(a);
    w.variant("d");
    w.double(1.5);
    w.boolean(true);
    // A byte, padding to 4, the uint.
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 0xef, 0xbe, 0xad, 0xde }, w.buf.items[0..8]);
    var r: Reader = .{ .data = w.buf.items };
    try testing.expectEqual(@as(u8, 7), try r.byte());
    try testing.expectEqual(@as(u32, 0xdeadbeef), try r.uint32());
    try testing.expectEqualStrings("héllo", try r.string());
    const end = try r.array(8);
    var count: i32 = 0;
    while (r.at < end) {
        try r.beginStruct();
        try testing.expectEqualStrings("x", try r.string());
        try testing.expectEqualStrings("/a/b", try r.string());
        try testing.expectEqual(count, try r.int32());
        count += 1;
    }
    try testing.expectEqual(@as(i32, 3), count);
    try testing.expectEqualStrings("d", try r.signature());
    try testing.expectEqual(@as(f64, 1.5), try r.double());
    try testing.expect(try r.boolean());
    // Skipping by signature lands in the same place.
    var s: Reader = .{ .data = w.buf.items };
    var sig: []const u8 = "yusa(soi)vb";
    while (sig.len > 0) sig = try s.skip(sig);
    try testing.expectEqual(w.buf.items.len, s.at);
}

test "messages are encoded and decoded, header fields and body" {
    var body: Writer = .{ .gpa = testing.allocator };
    defer body.deinit();
    body.string("org.a11y.atspi.Accessible");
    body.string("Name");
    const bytes = try encode(testing.allocator, .{
        .type = .method_call,
        .serial = 42,
        .path = "/org/a11y/atspi/accessible/root",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .destination = ":1.7",
        .signature = "ss",
    }, body.buf.items);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(bytes.len, (try messageLength(bytes)).?);
    const m = try decode(bytes);
    try testing.expectEqual(MessageType.method_call, m.header.type);
    try testing.expectEqual(@as(u32, 42), m.header.serial);
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/root", m.header.path.?);
    try testing.expectEqualStrings("Get", m.header.member.?);
    try testing.expectEqualStrings(":1.7", m.header.destination.?);
    try testing.expectEqualStrings("ss", m.header.signature);
    var r = m.reader();
    try testing.expectEqualStrings("org.a11y.atspi.Accessible", try r.string());
    try testing.expectEqualStrings("Name", try r.string());
    // Broken ones are refused.
    try testing.expectError(error.Malformed, decode(bytes[0 .. bytes.len - 1]));
    var bad_skip: Reader = .{ .data = &[_]u8{ 8, 0, 0, 0, 0, 0, 0, 0 } };
    try testing.expectError(error.Malformed, bad_skip.skip("a()"));
    try testing.expectError(error.Malformed, bad_skip.skip("a{}"));
    try testing.expectError(error.Malformed, bad_skip.skip("a)"));
}

test "addresses are unescaped" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/run/user/1/at-spi/bus", unescape("/run/user/1/at%2dspi/bus", &buf).?);
    try testing.expect(unescape("/bad%2", &buf) == null);
}
