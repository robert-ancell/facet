//! Reading GIF images: the first frame (of an animation too), with its
//! global or local palette, transparency and interlacing, on the image's
//! screen, transparent where the frame does not cover it (as browsers show
//! it). Decoded to 0xAARRGGBB pixels.

const std = @import("std");
const png = @import("png.zig");

pub const Error = png.Error;
pub const Decoded = png.Decoded;

/// Whether `data` looks like a GIF.
pub fn is(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a");
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (!is(data) or data.len < 13) return error.Malformed;
    var r: Reader = .{ .data = data, .at = 6 };
    const width = try r.u16le();
    const height = try r.u16le();
    const flags = try r.byte();
    r.at += 2; // Background and aspect.
    if (width == 0 or height == 0) return error.Malformed;
    if (@as(u64, width) * height > png.max_pixels) return error.TooBig;
    var global: [256]u32 = @splat(0xff000000);
    if (flags & 0x80 != 0) try r.palette(&global, flags);
    var transparent: ?u8 = null;
    while (true) switch (try r.byte()) {
        0x21 => {
            const label = try r.byte();
            if (label == 0xf9) {
                // Graphic control: which index is transparent.
                const size = try r.byte();
                const block = try r.take(size);
                if (size >= 4 and block[0] & 1 != 0) transparent = block[3];
            }
            try r.skipBlocks();
        },
        0x2c => {
            const left = try r.u16le();
            const top = try r.u16le();
            const fw = try r.u16le();
            const fh = try r.u16le();
            const fflags = try r.byte();
            var colors = global;
            if (fflags & 0x80 != 0) try r.palette(&colors, fflags);
            if (transparent) |t| colors[t] = 0;
            const min_size = try r.byte();
            if (min_size < 1 or min_size > 8) return error.Malformed;
            const indexes = try gpa.alloc(u8, @as(usize, fw) * fh);
            defer gpa.free(indexes);
            @memset(indexes, transparent orelse 0);
            try lzw(&r, min_size, indexes);
            const pixels = try gpa.alloc(u32, @as(usize, width) * height);
            @memset(pixels, 0);
            // The rows, in the order they were sent if interlaced.
            const order = [_][2]usize{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
            const passes: []const [2]usize = if (fflags & 0x40 != 0) &order else &.{.{ 0, 1 }};
            var row: usize = 0;
            for (passes) |pass| {
                var fy = pass[0];
                while (fy < fh) : (fy += pass[1]) {
                    const y = @as(usize, top) + fy;
                    defer row += 1;
                    if (y >= height) continue;
                    for (0..fw) |fx| {
                        const x = @as(usize, left) + fx;
                        if (x >= width) break;
                        pixels[y * width + x] = colors[indexes[row * fw + fx]];
                    }
                }
            }
            return .{ .pixels = pixels, .width = width, .height = height };
        },
        0x3b => return error.Malformed,
        else => return error.Malformed,
    };
}

const Reader = struct {
    data: []const u8,
    at: usize,

    fn byte(r: *Reader) Error!u8 {
        if (r.at >= r.data.len) return error.Malformed;
        r.at += 1;
        return r.data[r.at - 1];
    }

    fn u16le(r: *Reader) Error!u16 {
        return @as(u16, try r.byte()) | @as(u16, try r.byte()) << 8;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.at + n > r.data.len) return error.Malformed;
        r.at += n;
        return r.data[r.at - n .. r.at];
    }

    fn palette(r: *Reader, out: *[256]u32, flags: u8) Error!void {
        const n = @as(usize, 2) << @intCast(flags & 7);
        const rgb = try r.take(n * 3);
        for (0..n) |i| out[i] = 0xff000000 | @as(u32, rgb[i * 3]) << 16 | @as(u32, rgb[i * 3 + 1]) << 8 | rgb[i * 3 + 2];
    }

    fn skipBlocks(r: *Reader) Error!void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            _ = try r.take(n);
        }
    }
};

/// Decodes the frame's LZW-coded indexes (in sub-blocks) into `out`, as
/// many as there are room for.
fn lzw(r: *Reader, min_size: u8, out: []u8) Error!void {
    const clear: u16 = @as(u16, 1) << @intCast(min_size);
    const end = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var first: [4096]u8 = undefined;
    for (0..clear) |i| {
        suffix[i] = @intCast(i);
        first[i] = @intCast(i);
    }
    var next = clear + 2;
    var size: u4 = @intCast(min_size + 1);
    var prev: ?u16 = null;
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var block: usize = 0;
    var n: usize = 0;
    var stack: [4096]u8 = undefined;
    while (n < out.len) {
        while (nbits < size) {
            if (block == 0) {
                block = try r.byte();
                if (block == 0) return;
            }
            bits |= @as(u32, try r.byte()) << nbits;
            nbits += 8;
            block -= 1;
        }
        const code: u16 = @intCast(bits & ((@as(u32, 1) << size) - 1));
        bits >>= size;
        nbits -= size;
        if (code == clear) {
            next = clear + 2;
            size = @intCast(min_size + 1);
            prev = null;
            continue;
        }
        if (code == end) break;
        const p = prev orelse {
            if (code >= clear) return error.Malformed;
            out[n] = @intCast(code);
            n += 1;
            prev = code;
            continue;
        };
        // A code not yet made (the one being made now) is the previous
        // string and its first byte.
        var c = code;
        var sp: usize = 0;
        if (code >= next) {
            if (code > next) return error.Malformed;
            stack[0] = first[p];
            sp = 1;
            c = p;
        }
        while (c >= clear) {
            if (sp == stack.len) return error.Malformed;
            stack[sp] = suffix[c];
            sp += 1;
            c = prefix[c];
        }
        stack[sp] = @intCast(c);
        sp += 1;
        if (next < 4096) {
            prefix[next] = p;
            suffix[next] = @intCast(c);
            first[next] = first[p];
            next += 1;
            if (next == @as(u16, 1) << size and size < 12) size += 1;
        }
        while (sp > 0 and n < out.len) {
            sp -= 1;
            out[n] = stack[sp];
            n += 1;
        }
        prev = code;
    }
    // Past the image's data, to its end.
    while (block > 0) : (block -= 1) _ = try r.byte();
    try r.skipBlocks();
}

const testing = std.testing;

fn palette16(i: usize) u32 {
    return 0xff000000 | @as(u32, @intCast(i * 16 % 256)) << 16 | @as(u32, @intCast((255 - i * 16) % 256)) << 8 | @as(u32, @intCast(i * 37 % 256));
}

test "GIFs decode: plain, interlaced, transparent, animated, and a frame smaller than the screen" {
    for ([_]struct { []const u8, u32, bool }{
        .{ @embedFile("testdata/pattern.gif"), 13, false },
        .{ @embedFile("testdata/pattern_interlaced.gif"), 19, false },
        .{ @embedFile("testdata/pattern_transparent.gif"), 13, true },
        .{ @embedFile("testdata/pattern_animated.gif"), 13, false },
    }) |case| {
        const img = try decode(testing.allocator, case[0]);
        defer testing.allocator.free(img.pixels);
        try testing.expectEqual(@as(u32, 21), img.width);
        try testing.expectEqual(case[1], img.height);
        for (0..img.height) |y| for (0..21) |x| {
            const i = (x + y * 3) % 16;
            const want: u32 = if (case[2] and i == 0) 0 else palette16(i);
            try testing.expectEqual(want, img.pixels[y * 21 + x]);
        };
    }
    const img = try decode(testing.allocator, @embedFile("testdata/offset_frame.gif"));
    defer testing.allocator.free(img.pixels);
    try testing.expectEqualSlices(u32, &.{
        0, 0, 0,          0,          0,          0,
        0, 0, 0xffff0000, 0xff00ff00, 0xff0000ff, 0,
        0, 0, 0xffffff00, 0xff0000ff, 0xff00ff00, 0,
        0, 0, 0,          0,          0,          0,
    }, img.pixels);
}

test "broken GIFs are refused, and none crash" {
    try testing.expectError(error.Malformed, decode(testing.allocator, "GIF89a"));
    const good = @embedFile("testdata/pattern_interlaced.gif");
    var buf: [good.len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(2);
    for (0..500) |i| {
        @memcpy(&buf, good);
        const len = if (i % 3 == 0) prng.random().uintLessThan(usize, good.len) else good.len;
        if (i % 3 != 0) for (0..3) |_| {
            buf[prng.random().uintLessThan(usize, good.len)] = prng.random().int(u8);
        };
        if (decode(testing.allocator, buf[0..len])) |d| testing.allocator.free(d.pixels) else |_| {}
    }
}
