//! Reading WebP images (RFC 9649): lossless (VP8L) and lossy (VP8, see
//! vp8.zig) ones, with an alpha channel (ALPH), and the first frame of an
//! animation, on its canvas. Decoded to 0xAARRGGBB pixels.

const std = @import("std");
const png = @import("png.zig");
const vp8 = @import("vp8.zig");

pub const Error = png.Error;
pub const Decoded = png.Decoded;

/// Whether `data` looks like a WebP.
pub fn is(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    return decodeRegion(gpa, data, null);
}

/// Decodes part of a WebP image (all of it if `region` is null): a lossy
/// one only as far down as the region goes (see `vp8.decodeRegion`); a
/// lossless or animated one whole, then cut to it.
pub fn decodeRegion(gpa: std.mem.Allocator, data: []const u8, region: ?png.Region) Error!Decoded {
    if (!is(data)) return error.Malformed;
    var at: usize = 12;
    var canvas: ?[2]u32 = null;
    var alpha: ?[]const u8 = null;
    while (at + 8 <= data.len) {
        const kind = data[at..][0..4];
        const len = std.mem.readInt(u32, data[at + 4 ..][0..4], .little);
        if (len > data.len - at - 8) return error.Malformed;
        const body = data[at + 8 ..][0..len];
        at += 8 + len + (len & 1);
        if (std.mem.eql(u8, kind, "VP8X")) {
            if (len < 10) return error.Malformed;
            canvas = .{ u24le(body[4..7]) + 1, u24le(body[7..10]) + 1 };
        } else if (std.mem.eql(u8, kind, "ALPH")) {
            alpha = body;
        } else if (std.mem.eql(u8, kind, "VP8L")) {
            return cut(gpa, try lossless(gpa, body), region);
        } else if (std.mem.eql(u8, kind, "VP8 ")) {
            return lossy(gpa, body, alpha, region);
        } else if (std.mem.eql(u8, kind, "ANMF")) {
            const size = canvas orelse return error.Malformed;
            return cut(gpa, try firstFrame(gpa, body, size), region);
        }
    }
    return error.Malformed;
}

/// `img` cut to `region` (as it is if null), freeing it if cut.
fn cut(gpa: std.mem.Allocator, img: Decoded, region: ?png.Region) Error!Decoded {
    const r = region orelse return img;
    defer gpa.free(img.pixels);
    return png.crop(gpa, img, try png.Region.within(r, img.width, img.height));
}

fn u24le(b: *const [3]u8) u32 {
    return @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16;
}

/// An animation's first frame, where it goes on a transparent canvas.
fn firstFrame(gpa: std.mem.Allocator, body: []const u8, canvas: [2]u32) Error!Decoded {
    if (body.len < 16) return error.Malformed;
    if (@as(u64, canvas[0]) * canvas[1] > png.max_pixels) return error.TooBig;
    const fx = u24le(body[0..3]) * 2;
    const fy = u24le(body[3..6]) * 2;
    var at: usize = 16;
    var alpha: ?[]const u8 = null;
    const frame = while (at + 8 <= body.len) {
        const kind = body[at..][0..4];
        const len = std.mem.readInt(u32, body[at + 4 ..][0..4], .little);
        if (len > body.len - at - 8) return error.Malformed;
        const sub = body[at + 8 ..][0..len];
        at += 8 + len + (len & 1);
        if (std.mem.eql(u8, kind, "ALPH")) alpha = sub;
        if (std.mem.eql(u8, kind, "VP8L")) break try lossless(gpa, sub);
        if (std.mem.eql(u8, kind, "VP8 ")) break try lossy(gpa, sub, alpha, null);
    } else return error.Malformed;
    defer gpa.free(frame.pixels);
    const pixels = try gpa.alloc(u32, @as(usize, canvas[0]) * canvas[1]);
    @memset(pixels, 0);
    for (0..frame.height) |y| {
        if (fy + y >= canvas[1]) break;
        for (0..frame.width) |x| {
            if (fx + x >= canvas[0]) break;
            pixels[(fy + y) * canvas[0] + fx + x] = frame.pixels[y * frame.width + x];
        }
    }
    return .{ .pixels = pixels, .width = canvas[0], .height = canvas[1] };
}

/// A lossy image (or part of one), with its alpha channel if there is one.
fn lossy(gpa: std.mem.Allocator, body: []const u8, alpha: ?[]const u8, region: ?png.Region) Error!Decoded {
    const img = try vp8.decodeRegion(gpa, body, region);
    errdefer gpa.free(img.pixels);
    if (alpha) |a| {
        if (body.len < 10) return error.Malformed;
        const w: u32 = std.mem.readInt(u16, body[6..8], .little) & 0x3fff;
        const h: u32 = std.mem.readInt(u16, body[8..10], .little) & 0x3fff;
        try applyAlpha(gpa, img, a, w, h, try png.Region.within(region, w, h));
    }
    return img;
}

/// An ALPH chunk's alpha values (for an image `w` by `h`), put into
/// `img`'s pixels (its part `reg`).
fn applyAlpha(gpa: std.mem.Allocator, img: Decoded, chunk: []const u8, w: u32, h: u32, reg: png.Region) Error!void {
    if (chunk.len < 1) return error.Malformed;
    const filter = (chunk[0] >> 2) & 3;
    const method = chunk[0] & 3;
    const values = try gpa.alloc(u8, @as(usize, w) * h);
    defer gpa.free(values);
    switch (method) {
        0 => {
            if (chunk.len - 1 < values.len) return error.Malformed;
            @memcpy(values, chunk[1..][0..values.len]);
        },
        1 => {
            // A lossless image stream with no header, its green the alpha.
            var br: BitReader = .{ .data = chunk[1..] };
            const argb = try imageStream(gpa, &br, w, h);
            defer gpa.free(argb);
            for (values, argb) |*v, p| v.* = @truncate(p >> 8);
        },
        else => return error.Unsupported,
    }
    // Undo the filtering.
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        const left: u8 = if (x > 0) values[i - 1] else 0;
        const up: u8 = if (y > 0) values[i - w] else 0;
        const pred: u8 = if (x == 0 and y == 0) 0 else switch (filter) {
            0 => 0,
            1 => if (x > 0) left else up,
            2 => if (y > 0) up else left,
            else => if (x == 0) up else if (y == 0) left else blk: {
                const g = @as(i16, left) + up - values[i - w - 1];
                break :blk @intCast(std.math.clamp(g, 0, 255));
            },
        };
        values[i] +%= pred;
    };
    for (0..reg.h) |y| for (0..reg.w) |x| {
        const p = &img.pixels[y * reg.w + x];
        p.* = (p.* & 0x00ffffff) | @as(u32, values[(reg.y + y) * w + reg.x + x]) << 24;
    };
}

/// A VP8L chunk: its header, then its image stream.
fn lossless(gpa: std.mem.Allocator, body: []const u8) Error!Decoded {
    if (body.len < 5 or body[0] != 0x2f) return error.Malformed;
    var br: BitReader = .{ .data = body[1..] };
    const w = br.bits(14) + 1;
    const h = br.bits(14) + 1;
    _ = br.bits(1);
    if (br.bits(3) != 0) return error.Unsupported;
    if (@as(u64, w) * h > png.max_pixels) return error.TooBig;
    const pixels = try imageStream(gpa, &br, w, h);
    return .{ .pixels = pixels, .width = w, .height = h };
}

/// Bits, least significant first.
const BitReader = struct {
    data: []const u8,
    at: usize = 0,
    buf: u64 = 0,
    n: u7 = 0,
    /// Read past the end.
    eos: bool = false,

    fn bits(b: *BitReader, count: u5) u32 {
        if (count == 0) return 0;
        while (b.n < count) {
            const byte: u64 = if (b.at < b.data.len) b.data[b.at] else blk: {
                b.eos = true;
                break :blk 0;
            };
            b.at += 1;
            b.buf |= byte << @intCast(b.n);
            b.n += 8;
        }
        const v: u32 = @intCast(b.buf & ((@as(u64, 1) << count) - 1));
        b.buf >>= count;
        b.n -= count;
        return v;
    }
};

/// A canonical prefix code, read a bit at a time.
const Prefix = struct {
    /// Symbols by code length, then by value.
    symbols: []u16,
    /// How many codes there are of each length.
    counts: [16]u16 = @splat(0),
    /// The symbol, if there is only one (which takes no bits).
    only: ?u16 = null,

    fn read(p: *const Prefix, b: *BitReader) Error!u16 {
        if (p.only) |s| return s;
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            code |= @intCast(b.bits(1));
            const count: i32 = p.counts[len];
            if (code - count < first) return p.symbols[@intCast(index + code - first)];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.Malformed;
    }

    fn init(a: std.mem.Allocator, lengths: []const u8) Error!Prefix {
        var p: Prefix = .{ .symbols = &.{} };
        var nonzero: usize = 0;
        var last: u16 = 0;
        for (lengths, 0..) |l, i| if (l > 0) {
            p.counts[l] += 1;
            nonzero += 1;
            last = @intCast(i);
        };
        if (nonzero == 0) {
            p.only = 0;
            return p;
        }
        if (nonzero == 1) {
            p.only = last;
            return p;
        }
        // A complete code: neither too many nor too few.
        var left: i32 = 1;
        for (1..16) |len| {
            left = left * 2 - p.counts[len];
            if (left < 0) return error.Malformed;
        }
        if (left != 0) return error.Malformed;
        var offsets: [16]u16 = undefined;
        offsets[1] = 0;
        for (1..15) |len| offsets[len + 1] = offsets[len] + p.counts[len];
        p.symbols = try a.alloc(u16, nonzero);
        for (lengths, 0..) |l, i| if (l > 0) {
            p.symbols[offsets[l]] = @intCast(i);
            offsets[l] += 1;
        };
        return p;
    }
};

const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// Reads a prefix code over `alphabet` symbols.
fn readPrefix(a: std.mem.Allocator, b: *BitReader, alphabet: usize) Error!Prefix {
    const lengths = try a.alloc(u8, alphabet);
    @memset(lengths, 0);
    if (b.bits(1) == 1) {
        // Simple: one or two symbols.
        const two = b.bits(1) == 1;
        const s0 = b.bits(if (b.bits(1) == 1) 8 else 1);
        if (s0 >= alphabet) return error.Malformed;
        lengths[s0] = 1;
        if (two) {
            const s1 = b.bits(8);
            if (s1 >= alphabet) return error.Malformed;
            lengths[s1] = 1;
        }
        return Prefix.init(a, lengths);
    }
    var cl_lengths: [19]u8 = @splat(0);
    const n = b.bits(4) + 4;
    if (n > 19) return error.Malformed;
    for (code_length_order[0..n]) |i| cl_lengths[i] = @intCast(b.bits(3));
    const cl = try Prefix.init(a, &cl_lengths);
    var max = alphabet;
    if (b.bits(1) == 1) {
        const nbits: u5 = @intCast(2 + 2 * b.bits(3));
        max = 2 + b.bits(nbits);
        if (max > alphabet) return error.Malformed;
    }
    var i: usize = 0;
    var prev: u8 = 8;
    while (i < alphabet) {
        if (max == 0) break;
        max -= 1;
        const code = try cl.read(b);
        if (b.eos) return error.Malformed;
        if (code < 16) {
            lengths[i] = @intCast(code);
            i += 1;
            if (code != 0) prev = @intCast(code);
            continue;
        }
        const repeat: usize, const value: u8 = switch (code) {
            16 => .{ 3 + b.bits(2), prev },
            17 => .{ 3 + b.bits(3), 0 },
            else => .{ 11 + b.bits(7), 0 },
        };
        if (i + repeat > alphabet) return error.Malformed;
        @memset(lengths[i..][0..repeat], value);
        i += repeat;
    }
    return Prefix.init(a, lengths);
}

const Group = [5]Prefix;

/// An image stream (RFC 9649 3.8): transforms, then the pixels.
fn imageStream(gpa: std.mem.Allocator, b: *BitReader, width: u32, height: u32) Error![]u32 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Transform = struct {
        kind: u2,
        bits: u5 = 0,
        data: []u32 = &.{},
        /// The width before it (the colour indexing transform packs pixels).
        width: u32,
    };
    var transforms: [4]Transform = undefined;
    var count: usize = 0;
    var seen: u4 = 0;
    var w = width;
    while (b.bits(1) == 1) {
        if (count == 4) return error.Malformed;
        const kind: u2 = @intCast(b.bits(2));
        if (seen & (@as(u4, 1) << kind) != 0) return error.Malformed;
        seen |= @as(u4, 1) << kind;
        var t: Transform = .{ .kind = kind, .width = w };
        switch (kind) {
            0, 1 => {
                t.bits = @intCast(b.bits(3) + 2);
                t.data = try entropyImage(a, b, divUp(w, t.bits), divUp(height, t.bits), false);
            },
            2 => {},
            3 => {
                const size = b.bits(8) + 1;
                t.data = try entropyImage(a, b, size, 1, false);
                // Each colour is a difference from the one before.
                for (1..t.data.len) |i| t.data[i] = addPixels(t.data[i], t.data[i - 1]);
                t.bits = if (size <= 2) 3 else if (size <= 4) 2 else if (size <= 16) 1 else 0;
                w = divUp(w, t.bits);
            },
        }
        transforms[count] = t;
        count += 1;
    }
    var pixels = try entropyImage(a, b, w, height, true);
    // Last read, first undone.
    var i = count;
    while (i > 0) {
        i -= 1;
        const t = transforms[i];
        switch (t.kind) {
            0 => predict(pixels, t.width, height, t.bits, t.data),
            1 => colorTransform(pixels, t.width, height, t.bits, t.data),
            2 => for (pixels) |*p| {
                const g = (p.* >> 8) & 0xff;
                p.* = (p.* & 0xff00ff00) | ((((p.* >> 16) + g) & 0xff) << 16) | (((p.* & 0xff) + g) & 0xff);
            },
            3 => pixels = try unindex(a, pixels, t.width, height, t.bits, t.data),
        }
    }
    return gpa.dupe(u32, pixels);
}

fn divUp(v: u32, bits: u5) u32 {
    return (v + (@as(u32, 1) << bits) - 1) >> bits;
}

/// Each channel added, modulo 256.
fn addPixels(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

/// The pixels of an entropy-coded image (with meta prefix codes if it is
/// the main one).
fn entropyImage(a: std.mem.Allocator, b: *BitReader, w: u32, h: u32, main: bool) Error![]u32 {
    if (@as(u64, w) * h > png.max_pixels) return error.TooBig;
    var cache_bits: u5 = 0;
    if (b.bits(1) == 1) {
        cache_bits = @intCast(b.bits(4));
        if (cache_bits < 1 or cache_bits > 11) return error.Malformed;
    }
    var meta_bits: u5 = 0;
    var meta: []u32 = &.{};
    var meta_w: u32 = 0;
    var groups_n: usize = 1;
    if (main and b.bits(1) == 1) {
        meta_bits = @intCast(b.bits(3) + 2);
        meta_w = divUp(w, meta_bits);
        meta = try entropyImage(a, b, meta_w, divUp(h, meta_bits), false);
        for (meta) |m| groups_n = @max(groups_n, ((m >> 8) & 0xffff) + 1);
    }
    const cache_size: usize = if (cache_bits > 0) @as(usize, 1) << cache_bits else 0;
    const groups = try a.alloc(Group, groups_n);
    for (groups) |*g| {
        if (b.eos) return error.Malformed;
        g[0] = try readPrefix(a, b, 256 + 24 + cache_size);
        g[1] = try readPrefix(a, b, 256);
        g[2] = try readPrefix(a, b, 256);
        g[3] = try readPrefix(a, b, 256);
        g[4] = try readPrefix(a, b, 40);
        if (b.eos) return error.Malformed;
    }
    const cache = try a.alloc(u32, cache_size);
    @memset(cache, 0);
    const out = try a.alloc(u32, @as(usize, w) * h);
    var pos: usize = 0;
    var inserted: usize = 0;
    while (pos < out.len) {
        const x: u32 = @intCast(pos % w);
        const y: u32 = @intCast(pos / w);
        const g = if (meta.len > 0) &groups[(meta[(y >> meta_bits) * meta_w + (x >> meta_bits)] >> 8) & 0xffff] else &groups[0];
        const s = try g[0].read(b);
        if (b.eos) return error.Malformed;
        if (s < 256) {
            const r = try g[1].read(b);
            const bl = try g[2].read(b);
            const al = try g[3].read(b);
            out[pos] = @as(u32, al) << 24 | @as(u32, r) << 16 | @as(u32, s) << 8 | bl;
            pos += 1;
        } else if (s < 256 + 24) {
            const len = lz77Value(b, s - 256);
            const dcode = lz77Value(b, try g[4].read(b));
            const dist: usize = if (dcode > 120) dcode - 120 else blk: {
                const xy = distance_map[dcode - 1];
                const d = @as(i64, xy[0]) + @as(i64, xy[1]) * w;
                break :blk @intCast(@max(d, 1));
            };
            if (dist > pos or len > out.len - pos) return error.Malformed;
            for (0..len) |_| {
                out[pos] = out[pos - dist];
                pos += 1;
            }
        } else {
            const idx = s - (256 + 24);
            if (idx >= cache_size) return error.Malformed;
            out[pos] = cache[idx];
            pos += 1;
        }
        if (cache_size > 0) {
            while (inserted < pos) : (inserted += 1) {
                const c = out[inserted];
                cache[@intCast((0x1e35a7bd *% c) >> @intCast(32 - @as(u32, cache_bits)))] = c;
            }
        }
    }
    return out;
}

/// A length or distance, from its prefix code and extra bits.
fn lz77Value(b: *BitReader, code: u32) u32 {
    if (code < 4) return code + 1;
    const extra: u5 = @intCast((code - 2) >> 1);
    const offset = (2 + (code & 1)) << extra;
    return offset + b.bits(extra) + 1;
}

const distance_map = [120][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },
    .{ -1, 2 }, .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },
    .{ 1, 3 },  .{ -1, 3 }, .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },
    .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },  .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 },
    .{ 3, 3 },  .{ -3, 3 }, .{ 2, 4 },  .{ -2, 4 }, .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },
    .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },  .{ 1, 5 },  .{ -1, 5 },
    .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 }, .{ 4, 4 },
    .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },
    .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 }, .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },
    .{ -6, 2 }, .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 },
    .{ 6, 3 },  .{ -6, 3 }, .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },
    .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 }, .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 },
    .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 }, .{ 3, 7 },  .{ -3, 7 }, .{ 7, 3 },
    .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 }, .{ 8, 0 },  .{ 4, 7 },
    .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },  .{ -6, 6 },
    .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },
    .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },
    .{ 8, 7 },
};

fn channel(p: u32, shift: u5) i32 {
    return @intCast((p >> shift) & 0xff);
}

fn average2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) + (a & b);
}

fn select(l: u32, t: u32, tl: u32) u32 {
    var pl: i32 = 0;
    var pt: i32 = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |s| {
        const p = channel(l, s) + channel(t, s) - channel(tl, s);
        pl += @intCast(@abs(p - channel(l, s)));
        pt += @intCast(@abs(p - channel(t, s)));
    }
    return if (pl < pt) l else t;
}

fn clampAddSubtractFull(a: u32, b: u32, c: u32) u32 {
    var out: u32 = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |s| {
        const v = std.math.clamp(channel(a, s) + channel(b, s) - channel(c, s), 0, 255);
        out |= @as(u32, @intCast(v)) << s;
    }
    return out;
}

fn clampAddSubtractHalf(a: u32, b: u32) u32 {
    var out: u32 = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |s| {
        const av = channel(a, s);
        const v = std.math.clamp(av + @divTrunc(av - channel(b, s), 2), 0, 255);
        out |= @as(u32, @intCast(v)) << s;
    }
    return out;
}

/// Undoes the predictor transform.
fn predict(px: []u32, w: u32, h: u32, bits: u5, modes: []const u32) void {
    const tw = divUp(w, bits);
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        const pred: u32 = if (y == 0)
            (if (x == 0) 0xff000000 else px[i - 1])
        else if (x == 0)
            px[i - w]
        else blk: {
            const l = px[i - 1];
            const t = px[i - w];
            const tl = px[i - w - 1];
            // On the right edge, the leftmost pixel of this row.
            const tr = if (x + 1 < w) px[i - w + 1] else px[i - x];
            const mode = (modes[(y >> bits) * tw + (x >> bits)] >> 8) & 0xff;
            break :blk switch (mode) {
                0 => 0xff000000,
                1 => l,
                2 => t,
                3 => tr,
                4 => tl,
                5 => average2(average2(l, tr), t),
                6 => average2(l, tl),
                7 => average2(l, t),
                8 => average2(tl, t),
                9 => average2(t, tr),
                10 => average2(average2(l, tl), average2(t, tr)),
                11 => select(l, t, tl),
                12 => clampAddSubtractFull(l, t, tl),
                13 => clampAddSubtractHalf(average2(l, t), tl),
                else => 0xff000000,
            };
        };
        px[i] = addPixels(px[i], pred);
    };
}

fn delta(t: u8, c: u8) i32 {
    return (@as(i32, @as(i8, @bitCast(t))) * @as(i8, @bitCast(c))) >> 5;
}

/// Undoes the colour transform.
fn colorTransform(px: []u32, w: u32, h: u32, bits: u5, elems: []const u32) void {
    const tw = divUp(w, bits);
    for (0..h) |y| for (0..w) |x| {
        const p = &px[y * w + x];
        const e = elems[(y >> bits) * tw + (x >> bits)];
        const g2r: u8 = @truncate(e);
        const g2b: u8 = @truncate(e >> 8);
        const r2b: u8 = @truncate(e >> 16);
        const green: u8 = @truncate(p.* >> 8);
        var red: i32 = @intCast((p.* >> 16) & 0xff);
        var blue: i32 = @intCast(p.* & 0xff);
        red += delta(g2r, green);
        blue += delta(g2b, green);
        blue += delta(r2b, @truncate(@as(u32, @bitCast(red)) & 0xff));
        p.* = (p.* & 0xff00ff00) | (@as(u32, @bitCast(red)) & 0xff) << 16 | (@as(u32, @bitCast(blue)) & 0xff);
    };
}

/// Undoes the colour indexing transform: indexes (packed `bits` to a
/// pixel) to colours.
fn unindex(a: std.mem.Allocator, px: []const u32, w: u32, h: u32, bits: u5, table: []const u32) Error![]u32 {
    const out = try a.alloc(u32, @as(usize, w) * h);
    const packed_w = divUp(w, bits);
    const per: u5 = @intCast(@as(u32, 8) >> bits);
    const mask: u32 = (@as(u32, 1) << per) - 1;
    for (0..h) |y| for (0..w) |x| {
        const g = (px[y * packed_w + (x >> bits)] >> 8) & 0xff;
        const shift: u5 = @intCast((x & ((@as(usize, 1) << bits) - 1)) * per);
        const index = if (bits == 0) g else (g >> shift) & mask;
        out[y * w + x] = if (index < table.len) table[index] else 0;
    };
    return out;
}

const testing = std.testing;

test "WebPs decode as libwebp does: lossless, lossy, with alpha, and an animation's first frame" {
    // CRC-32s of libwebp's pixels (as Pillow decodes them), 0xAARRGGBB.
    const cases = .{
        .{ "animated.webp", 0x6ed0cfff },
        .{ "lossless_gradient.webp", 0x6ed0cfff },
        .{ "lossless_noise.webp", 0x701b82ce },
        .{ "lossless_palette.webp", 0x4830e160 },
        .{ "lossy.webp", 0x8191477b },
        .{ "lossy_alpha.webp", 0xde9bc3e4 },
        .{ "lossy_low.webp", 0x7c725969 },
    };
    inline for (cases) |case| {
        const img = try decode(testing.allocator, @embedFile("testdata/" ++ case[0]));
        defer testing.allocator.free(img.pixels);
        try testing.expectEqual(@as(u32, 61), img.width);
        try testing.expectEqual(@as(u32, 37), img.height);
        testing.expectEqual(@as(u32, case[1]), std.hash.Crc32.hash(std.mem.sliceAsBytes(img.pixels))) catch |err| {
            std.debug.print("{s} differs\n", .{case[0]});
            return err;
        };
    }
    // The lossless gradient, exactly.
    const img = try decode(testing.allocator, @embedFile("testdata/lossless_gradient.webp"));
    defer testing.allocator.free(img.pixels);
    for (0..37) |y| for (0..61) |x| {
        const r: u32 = @intCast(x * 4 % 256);
        const g: u32 = @intCast(y * 6 % 256);
        const b: u32 = @intCast(x * y % 256);
        const a: u32 = @intCast(255 - x * 2);
        try testing.expectEqual(a << 24 | r << 16 | g << 8 | b, img.pixels[y * 61 + x]);
    };
}

test "parts of WebPs decode to those parts" {
    inline for (.{ "animated.webp", "lossless_noise.webp", "lossy.webp", "lossy_alpha.webp", "lossy_low.webp" }) |name| {
        const data = @embedFile("testdata/" ++ name);
        const full = try decode(testing.allocator, data);
        defer testing.allocator.free(full.pixels);
        for ([_]png.Region{ .{ .x = 5, .y = 3, .w = 20, .h = 10 }, .{ .x = 0, .y = 17, .w = 61, .h = 3 }, .{ .x = 40, .y = 30, .w = 99, .h = 99 } }) |reg| {
            const part = try decodeRegion(testing.allocator, data, reg);
            defer testing.allocator.free(part.pixels);
            png.expectRegion(full, part, try png.Region.within(reg, full.width, full.height)) catch |err| {
                std.debug.print("{s} differs\n", .{name});
                return err;
            };
        }
    }
}

test "broken WebPs are refused, and none crash" {
    try testing.expectError(error.Malformed, decode(testing.allocator, "RIFF\x00\x00\x00\x00WEBP"));
    inline for (.{ "lossless_noise.webp", "lossy_alpha.webp", "animated.webp" }) |name| {
        const good = @embedFile("testdata/" ++ name);
        var buf: [good.len]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(3);
        for (0..300) |i| {
            @memcpy(&buf, good);
            const len = if (i % 3 == 0) prng.random().uintLessThan(usize, good.len) else good.len;
            if (i % 3 != 0) for (0..3) |_| {
                buf[prng.random().uintLessThan(usize, good.len)] = prng.random().int(u8);
            };
            if (decode(testing.allocator, buf[0..len])) |d| testing.allocator.free(d.pixels) else |_| {}
        }
    }
}
