//! Reading JPEG images: baseline and progressive (Huffman coded, 8-bit),
//! grey, YCbCr, and Adobe's CMYK and YCCK, any chroma subsampling, with
//! restart intervals, turned as its EXIF orientation says. Decoded to
//! 0xAARRGGBB pixels (opaque). Not read:
//! arithmetic coding, 12-bit and lossless JPEGs.
//!
//! Every scan's coefficients are kept, then turned into pixels once the
//! last is read, so progressive images are read the same way as baseline
//! ones.

const std = @import("std");
const png = @import("png.zig");

pub const Error = png.Error;
pub const Decoded = png.Decoded;

/// Whether `data` looks like a JPEG.
pub fn is(data: []const u8) bool {
    return data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff;
}

/// Decodes a JPEG image.
pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    var d: Decoder = .{ .gpa = gpa, .data = data };
    defer d.deinit();
    return d.run();
}

/// Where the coefficients of an 8×8 block go, in the order they are sent.
const dezigzag = [64 + 16]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
    // Past the end (a corrupt run): somewhere harmless.
    63, 63, 63, 63, 63, 63, 63, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
};

const Huffman = struct {
    /// By the next 9 bits: the symbol and its code's length (0 if longer).
    fast: [512]u16 = @splat(0),
    /// For codes of each length: the largest code (+1), and where its
    /// symbols start.
    maxcode: [18]u32 = @splat(0),
    delta: [17]i32 = @splat(0),
    symbols: [256]u8 = @splat(0),

    fn build(counts: [16]u8, symbols: []const u8) Error!Huffman {
        var h: Huffman = .{};
        @memcpy(h.symbols[0..symbols.len], symbols);
        var code: u32 = 0;
        var k: usize = 0;
        for (0..16) |i| {
            const len = i + 1;
            h.delta[len] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            for (0..counts[i]) |_| {
                if (len <= 9) {
                    const shift: u4 = @intCast(9 - len);
                    const first = code << shift;
                    for (0..@as(usize, 1) << shift) |j| h.fast[first + j] = @as(u16, @intCast(len)) << 8 | symbols[k];
                }
                code += 1;
                k += 1;
            }
            if (code > @as(u32, 1) << @intCast(len)) return error.Malformed;
            h.maxcode[len] = code << @intCast(16 - len);
            code <<= 1;
        }
        h.maxcode[17] = 0xffffffff;
        return h;
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    quant: u8,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    dc_pred: i32 = 0,
    /// Its blocks across and down (whole MCUs' worth), and their
    /// coefficients, in natural order.
    blocks_w: usize = 0,
    blocks_h: usize = 0,
    coefs: []i16 = &.{},
    /// Pixels, `blocks_w * 8` across.
    pixels: []u8 = &.{},
};

const Decoder = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    at: usize = 0,
    // The entropy-coded data's bits.
    bits: u32 = 0,
    nbits: u6 = 0,
    marker_hit: bool = false,

    quant: [4][64]u16 = @splat(@splat(1)),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),
    comps: [4]Component = undefined,
    ncomps: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    progressive: bool = false,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcus_x: usize = 0,
    mcus_y: usize = 0,
    restart_interval: u32 = 0,
    eobrun: u32 = 0,
    /// Adobe's colour transform (APP14): 0 none (RGB or CMYK), 1 YCbCr,
    /// 2 YCCK; null without the marker.
    adobe: ?u8 = null,
    jfif: bool = false,
    /// EXIF's orientation (1 to 8; 1 as it is).
    orientation: u8 = 1,

    fn deinit(d: *Decoder) void {
        for (d.comps[0..d.ncomps]) |c| {
            d.gpa.free(c.coefs);
            d.gpa.free(c.pixels);
        }
    }

    fn byte(d: *Decoder) Error!u8 {
        if (d.at >= d.data.len) return error.Malformed;
        d.at += 1;
        return d.data[d.at - 1];
    }

    fn u16be(d: *Decoder) Error!u16 {
        return @as(u16, try d.byte()) << 8 | try d.byte();
    }

    /// The next marker, skipping anything before it.
    fn marker(d: *Decoder) Error!u8 {
        while (true) {
            var b = try d.byte();
            if (b != 0xff) continue;
            while (b == 0xff) b = try d.byte();
            if (b != 0) return b;
        }
    }

    /// A segment's body (after its length).
    fn segment(d: *Decoder) Error![]const u8 {
        const len = try d.u16be();
        if (len < 2 or d.at + len - 2 > d.data.len) return error.Malformed;
        const body = d.data[d.at..][0 .. len - 2];
        d.at += len - 2;
        return body;
    }

    fn run(d: *Decoder) Error!Decoded {
        if (!is(d.data)) return error.Malformed;
        d.at = 2;
        var frame = false;
        while (true) {
            const m = try d.marker();
            switch (m) {
                0xd8, 0x01, 0xd0...0xd7 => {},
                0xd9 => break,
                0xdb => try d.readQuant(try d.segment()),
                0xc4 => try d.readHuffman(try d.segment()),
                0xdd => {
                    const body = try d.segment();
                    if (body.len < 2) return error.Malformed;
                    d.restart_interval = std.mem.readInt(u16, body[0..2], .big);
                },
                0xc0, 0xc1, 0xc2 => {
                    if (frame) return error.Malformed;
                    d.progressive = m == 0xc2;
                    try d.readFrame(try d.segment());
                    frame = true;
                },
                0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => return error.Unsupported,
                0xda => {
                    if (!frame) return error.Malformed;
                    try d.readScan(try d.segment());
                },
                0xee => {
                    const body = try d.segment();
                    if (body.len >= 12 and std.mem.startsWith(u8, body, "Adobe")) d.adobe = body[11];
                },
                0xe1 => {
                    const body = try d.segment();
                    if (exifOrientation(body)) |o| d.orientation = o;
                },
                0xe0 => {
                    const body = try d.segment();
                    if (std.mem.startsWith(u8, body, "JFIF\x00")) d.jfif = true;
                },
                else => _ = try d.segment(),
            }
        }
        if (!frame) return error.Malformed;
        return d.finish();
    }

    fn readQuant(d: *Decoder, body: []const u8) Error!void {
        var i: usize = 0;
        while (i < body.len) {
            const pq = body[i] >> 4;
            const tq = body[i] & 15;
            i += 1;
            if (tq > 3 or pq > 1) return error.Malformed;
            const size: usize = if (pq == 1) 128 else 64;
            if (i + size > body.len) return error.Malformed;
            for (0..64) |k| {
                d.quant[tq][dezigzag[k]] = if (pq == 1) std.mem.readInt(u16, body[i + k * 2 ..][0..2], .big) else body[i + k];
            }
            i += size;
        }
    }

    fn readHuffman(d: *Decoder, body: []const u8) Error!void {
        var i: usize = 0;
        while (i < body.len) {
            if (i + 17 > body.len) return error.Malformed;
            const tc = body[i] >> 4;
            const th = body[i] & 15;
            if (tc > 1 or th > 3) return error.Malformed;
            var counts: [16]u8 = undefined;
            @memcpy(&counts, body[i + 1 ..][0..16]);
            var total: usize = 0;
            for (counts) |c| total += c;
            i += 17;
            if (total > 256 or i + total > body.len) return error.Malformed;
            const h = try Huffman.build(counts, body[i..][0..total]);
            if (tc == 0) d.dc[th] = h else d.ac[th] = h;
            i += total;
        }
    }

    fn readFrame(d: *Decoder, body: []const u8) Error!void {
        if (body.len < 6) return error.Malformed;
        if (body[0] != 8) return error.Unsupported;
        d.height = std.mem.readInt(u16, body[1..3], .big);
        d.width = std.mem.readInt(u16, body[3..5], .big);
        const n: usize = body[5];
        if (d.width == 0 or d.height == 0) return error.Unsupported;
        if (@as(u64, d.width) * d.height > png.max_pixels) return error.TooBig;
        if (n != 1 and n != 3 and n != 4) return error.Unsupported;
        if (body.len < 6 + n * 3) return error.Malformed;
        for (d.comps[0..n], 0..) |*c, i| {
            const s = body[6 + i * 3 ..][0..3];
            c.* = .{ .id = s[0], .h = s[1] >> 4, .v = s[1] & 15, .quant = s[2] & 3 };
            if (c.h < 1 or c.h > 4 or c.v < 1 or c.v > 4) return error.Malformed;
            d.hmax = @max(d.hmax, c.h);
            d.vmax = @max(d.vmax, c.v);
        }
        d.mcus_x = std.math.divCeil(usize, d.width, @as(usize, d.hmax) * 8) catch unreachable;
        d.mcus_y = std.math.divCeil(usize, d.height, @as(usize, d.vmax) * 8) catch unreachable;
        // Counted as they are made, for `deinit` to free.
        for (d.comps[0..n]) |*c| {
            c.blocks_w = d.mcus_x * c.h;
            c.blocks_h = d.mcus_y * c.v;
            c.coefs = try d.gpa.alloc(i16, c.blocks_w * c.blocks_h * 64);
            @memset(c.coefs, 0);
            d.ncomps += 1;
        }
    }

    fn readScan(d: *Decoder, body: []const u8) Error!void {
        if (body.len < 1) return error.Malformed;
        const n = body[0];
        if (n < 1 or n > 4 or body.len < 1 + n * 2 + 3) return error.Malformed;
        var scan: [4]*Component = undefined;
        for (0..n) |i| {
            const id = body[1 + i * 2];
            const tables = body[2 + i * 2];
            const c = for (d.comps[0..d.ncomps]) |*c| {
                if (c.id == id) break c;
            } else return error.Malformed;
            c.dc_table = (tables >> 4) & 3;
            c.ac_table = tables & 3;
            scan[i] = c;
        }
        const tail = body[1 + n * 2 ..];
        const ss = tail[0];
        const se = tail[1];
        const ah: u4 = @intCast(tail[2] >> 4);
        const al: u4 = @intCast(tail[2] & 15);
        if (d.progressive) {
            if (ss > se or se > 63 or (ss == 0 and se != 0) or (ss > 0 and n != 1) or al > 13) return error.Malformed;
        }
        const s: Scan = .{ .ss = if (d.progressive) ss else 0, .se = if (d.progressive) se else 63, .ah = ah, .al = al };
        d.resetBits();
        for (d.comps[0..d.ncomps]) |*c| c.dc_pred = 0;
        d.eobrun = 0;
        var todo = d.restart_interval;
        if (n == 1) {
            // One component: its own blocks, those of the picture, in order.
            const c = scan[0];
            const w = std.math.divCeil(usize, std.math.divCeil(usize, @as(usize, d.width) * c.h, d.hmax) catch unreachable, 8) catch unreachable;
            const h = std.math.divCeil(usize, std.math.divCeil(usize, @as(usize, d.height) * c.v, d.vmax) catch unreachable, 8) catch unreachable;
            for (0..h) |by| for (0..w) |bx| {
                try d.restart(&todo);
                try d.block(c, by * c.blocks_w + bx, s);
            };
        } else {
            for (0..d.mcus_y) |my| for (0..d.mcus_x) |mx| {
                try d.restart(&todo);
                for (scan[0..n]) |c| for (0..c.v) |v| for (0..c.h) |hh| {
                    try d.block(c, (my * c.v + v) * c.blocks_w + mx * c.h + hh, s);
                };
            };
        }
        // Up to the next marker.
        d.resetBits();
    }

    const Scan = struct { ss: u8, se: u8, ah: u4, al: u4 };

    /// Before each MCU: after `restart_interval` of them, the restart
    /// marker, and the predictions start over.
    fn restart(d: *Decoder, todo: *u32) Error!void {
        if (d.restart_interval == 0) return;
        if (todo.* == 0) {
            d.resetBits();
            const m = try d.marker();
            if (m < 0xd0 or m > 0xd7) {
                // Missing: carry on from it.
                d.at -= 2;
            }
            for (d.comps[0..d.ncomps]) |*c| c.dc_pred = 0;
            d.eobrun = 0;
            todo.* = d.restart_interval;
        }
        todo.* -= 1;
    }

    fn resetBits(d: *Decoder) void {
        d.bits = 0;
        d.nbits = 0;
        if (d.marker_hit) {
            d.marker_hit = false;
        }
    }

    fn fill(d: *Decoder) void {
        while (d.nbits <= 24) {
            var b: u32 = 0;
            if (!d.marker_hit and d.at < d.data.len) {
                b = d.data[d.at];
                if (b == 0xff) {
                    const next: u8 = if (d.at + 1 < d.data.len) d.data[d.at + 1] else 0xd9;
                    if (next == 0) {
                        d.at += 2;
                    } else {
                        // A marker: the data ends; zeros after.
                        d.marker_hit = true;
                        b = 0;
                    }
                } else d.at += 1;
            }
            d.bits |= b << @intCast(24 - @as(u32, d.nbits));
            d.nbits += 8;
        }
    }

    fn getBits(d: *Decoder, n: u5) u32 {
        if (n == 0) return 0;
        d.fill();
        const v = d.bits >> @intCast(32 - @as(u32, n));
        d.bits <<= n;
        d.nbits -= n;
        return v;
    }

    fn getBit(d: *Decoder) bool {
        return d.getBits(1) == 1;
    }

    /// `n` bits as a signed value (JPEG's "extend").
    fn receive(d: *Decoder, n: u5) i32 {
        if (n == 0) return 0;
        if (n > 16) return 0;
        const v: i32 = @intCast(d.getBits(n));
        return if (v < (@as(i32, 1) << (n - 1))) v - (@as(i32, 1) << n) + 1 else v;
    }

    fn decodeHuffman(d: *Decoder, h: *const Huffman) Error!u8 {
        d.fill();
        const fast = h.fast[d.bits >> 23];
        if (fast != 0) {
            const len: u5 = @intCast(fast >> 8);
            d.bits <<= len;
            d.nbits -= len;
            return @truncate(fast);
        }
        const top = d.bits >> 16;
        var len: usize = 10;
        while (len <= 16) : (len += 1) if (top < h.maxcode[len]) break;
        if (len > 16) return error.Malformed;
        const code: i32 = @intCast(top >> @intCast(16 - len));
        const index = code + h.delta[len];
        if (index < 0 or index > 255) return error.Malformed;
        d.bits <<= @intCast(len);
        d.nbits -= @intCast(len);
        return h.symbols[@intCast(index)];
    }

    fn block(d: *Decoder, c: *Component, index: usize, s: Scan) Error!void {
        const coef = c.coefs[index * 64 ..][0..64];
        if (!d.progressive) return d.baseline(c, coef);
        if (s.ss == 0) {
            if (s.ah == 0) {
                const t = try d.decodeHuffman(&d.dc[c.dc_table]);
                c.dc_pred +%= d.receive(@intCast(@min(t, 16)));
                coef[0] = @truncate(c.dc_pred *% (@as(i32, 1) << s.al));
            } else if (d.getBit()) {
                coef[0] |= @as(i16, 1) << s.al;
            }
            return;
        }
        if (s.ah == 0) return d.acFirst(c, coef, s);
        return d.acRefine(c, coef, s);
    }

    fn baseline(d: *Decoder, c: *Component, coef: *[64]i16) Error!void {
        const t = try d.decodeHuffman(&d.dc[c.dc_table]);
        c.dc_pred +%= d.receive(@intCast(@min(t, 16)));
        coef[0] = @truncate(c.dc_pred);
        var k: usize = 1;
        while (k < 64) {
            const rs = try d.decodeHuffman(&d.ac[c.ac_table]);
            const r = rs >> 4;
            const size = rs & 15;
            if (size == 0) {
                if (r != 15) break;
                k += 16;
                continue;
            }
            k += r;
            coef[dezigzag[@min(k, 79)]] = @truncate(d.receive(@intCast(size)));
            k += 1;
        }
    }

    fn acFirst(d: *Decoder, c: *Component, coef: *[64]i16, s: Scan) Error!void {
        if (d.eobrun > 0) {
            d.eobrun -= 1;
            return;
        }
        var k: usize = s.ss;
        while (k <= s.se) {
            const rs = try d.decodeHuffman(&d.ac[c.ac_table]);
            const r: u5 = @intCast(rs >> 4);
            const size = rs & 15;
            if (size == 0) {
                if (r < 15) {
                    d.eobrun = (@as(u32, 1) << r) - 1;
                    if (r > 0) d.eobrun += d.getBits(r);
                    break;
                }
                k += 16;
                continue;
            }
            k += r;
            coef[dezigzag[@min(k, 79)]] = @truncate(d.receive(@intCast(size)) *% (@as(i32, 1) << s.al));
            k += 1;
        }
    }

    fn acRefine(d: *Decoder, c: *Component, coef: *[64]i16, s: Scan) Error!void {
        const bit: i16 = @as(i16, 1) << s.al;
        if (d.eobrun > 0) {
            d.eobrun -= 1;
            for (s.ss..@as(usize, s.se) + 1) |k| d.refine(&coef[dezigzag[k]], bit);
            return;
        }
        var k: usize = s.ss;
        while (k <= s.se) {
            const rs = try d.decodeHuffman(&d.ac[c.ac_table]);
            var r: u32 = rs >> 4;
            const size = rs & 15;
            var value: i16 = 0;
            if (size == 0) {
                if (r < 15) {
                    d.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                    if (r > 0) d.eobrun += d.getBits(@intCast(r));
                    // The rest of this block only refines.
                    r = 64;
                }
            } else {
                if (size != 1) return error.Malformed;
                value = if (d.getBit()) bit else -bit;
            }
            // Past `r` zero coefficients (refining those that are not).
            while (k <= s.se) {
                const p = &coef[dezigzag[k]];
                k += 1;
                if (p.* != 0) {
                    d.refine(p, bit);
                } else {
                    if (r == 0) {
                        p.* = value;
                        break;
                    }
                    r -= 1;
                }
            }
        }
    }

    fn refine(d: *Decoder, p: *i16, bit: i16) void {
        if (p.* == 0 or !d.getBit() or p.* & bit != 0) return;
        p.* = if (p.* > 0) p.* +% bit else p.* -% bit;
    }

    fn finish(d: *Decoder) Error!Decoded {
        // Each component's pixels.
        for (d.comps[0..d.ncomps]) |*c| {
            const stride = c.blocks_w * 8;
            c.pixels = try d.gpa.alloc(u8, stride * c.blocks_h * 8);
            const q = &d.quant[c.quant];
            for (0..c.blocks_h) |by| for (0..c.blocks_w) |bx| {
                const coef = c.coefs[(by * c.blocks_w + bx) * 64 ..][0..64];
                var deq: [64]i32 = undefined;
                for (&deq, coef, q) |*o, v, m| o.* = std.math.clamp(@as(i32, v) * m, -32768, 32767);
                idct(c.pixels[by * 8 * stride + bx * 8 ..], stride, &deq);
            };
        }
        const out = try d.gpa.alloc(u32, @as(usize, d.width) * d.height);
        errdefer d.gpa.free(out);
        // RGB unless the Adobe marker says so; grey; YCbCr; CMYK or YCCK.
        const transform: u8 = d.adobe orelse if (d.ncomps == 3) blk: {
            const ids = [3]u8{ d.comps[0].id, d.comps[1].id, d.comps[2].id };
            break :blk if (!d.jfif and std.mem.eql(u8, &ids, "RGB")) 0 else 1;
        } else 0;
        for (0..d.height) |y| for (0..d.width) |x| {
            var v: [4]u8 = undefined;
            for (d.comps[0..d.ncomps], 0..) |*c, i| {
                // Nearest of the component's samples to the pixel.
                const sx = x * c.h / d.hmax;
                const sy = y * c.v / d.vmax;
                v[i] = c.pixels[sy * c.blocks_w * 8 + sx];
            }
            out[y * d.width + x] = switch (d.ncomps) {
                1 => argb(v[0], v[0], v[0]),
                3 => if (transform == 0) argb(v[0], v[1], v[2]) else ycbcr(v[0], v[1], v[2]),
                else => blk: {
                    const rgb = if (transform == 2) ycbcr(v[0], v[1], v[2]) else argb(v[0], v[1], v[2]);
                    var r: u8 = @truncate(rgb >> 16);
                    var g: u8 = @truncate(rgb >> 8);
                    var b: u8 = @truncate(rgb);
                    if (transform == 2) {
                        r = 255 - r;
                        g = 255 - g;
                        b = 255 - b;
                    }
                    break :blk argb(mul8(r, v[3]), mul8(g, v[3]), mul8(b, v[3]));
                },
            };
        };
        const img: Decoded = .{ .pixels = out, .width = d.width, .height = d.height };
        if (d.orientation == 1) return img;
        defer d.gpa.free(out);
        return orient(d.gpa, img, d.orientation);
    }
};

/// The orientation in an APP1 segment's EXIF (its TIFF header, then the
/// first IFD's tag 0x0112), if it has one.
fn exifOrientation(body: []const u8) ?u8 {
    if (body.len < 14 or !std.mem.startsWith(u8, body, "Exif\x00\x00")) return null;
    const tiff = body[6..];
    const endian: std.builtin.Endian = if (std.mem.startsWith(u8, tiff, "II")) .little else if (std.mem.startsWith(u8, tiff, "MM")) .big else return null;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len - 2) return null;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    for (0..count) |i| {
        const at = ifd + 2 + i * 12;
        if (at + 12 > tiff.len) return null;
        const entry = tiff[at..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) != 0x0112) continue;
        const v = std.mem.readInt(u16, entry[8..10], endian);
        return if (v >= 1 and v <= 8) @intCast(v) else null;
    }
    return null;
}

/// `img` turned or flipped as an EXIF orientation says: 2 flipped across,
/// 3 turned half round, 4 flipped down, 5 transposed, 6 turned a quarter
/// clockwise, 7 transposed the other way, 8 turned a quarter anticlockwise.
fn orient(gpa: std.mem.Allocator, img: Decoded, o: u8) Error!Decoded {
    const w = img.width;
    const h = img.height;
    const sideways = o >= 5;
    const ow = if (sideways) h else w;
    const oh = if (sideways) w else h;
    const out = try gpa.alloc(u32, img.pixels.len);
    for (0..oh) |y| for (0..ow) |x| {
        const sx: usize, const sy: usize = switch (o) {
            2 => .{ w - 1 - x, y },
            3 => .{ w - 1 - x, h - 1 - y },
            4 => .{ x, h - 1 - y },
            5 => .{ y, x },
            6 => .{ y, h - 1 - x },
            7 => .{ w - 1 - y, h - 1 - x },
            8 => .{ w - 1 - y, x },
            else => .{ x, y },
        };
        out[y * ow + x] = img.pixels[sy * w + sx];
    };
    return .{ .pixels = out, .width = ow, .height = oh };
}

fn argb(r: u8, g: u8, b: u8) u32 {
    return 0xff000000 | @as(u32, r) << 16 | @as(u32, g) << 8 | b;
}

/// x·y/255, rounded.
fn mul8(x: u8, y: u8) u8 {
    const t = @as(u32, x) * y + 128;
    return @intCast((t + (t >> 8)) >> 8);
}

fn ycbcr(y: u8, cb: u8, cr: u8) u32 {
    const yy = @as(i32, y) << 16;
    const b_ = @as(i32, cb) - 128;
    const r_ = @as(i32, cr) - 128;
    const r = (yy + 91881 * r_ + 32768) >> 16;
    const g = (yy - 22554 * b_ - 46802 * r_ + 32768) >> 16;
    const b = (yy + 116130 * b_ + 32768) >> 16;
    return argb(clamp(r), clamp(g), clamp(b));
}

fn clamp(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// An 8×8 block's dequantized coefficients (natural order) to pixels: the
/// integer inverse DCT that stb_image and libjpeg use.
fn idct(out: []u8, stride: usize, data: *const [64]i32) void {
    const f2f = struct {
        fn f(comptime x: f32) i32 {
            return @intFromFloat(x * 4096 + 0.5);
        }
    }.f;
    const Pass = struct {
        x0: i32,
        x1: i32,
        x2: i32,
        x3: i32,
        t0: i32,
        t1: i32,
        t2: i32,
        t3: i32,

        fn of(s0: i32, s1: i32, s2: i32, s3: i32, s4: i32, s5: i32, s6: i32, s7: i32) @This() {
            var p2 = s2;
            var p3 = s6;
            var p1 = (p2 +% p3) *% f2f(0.5411961);
            var t2 = p1 +% p3 *% f2f(-1.847759065);
            var t3 = p1 +% p2 *% f2f(0.765366865);
            p2 = s0;
            p3 = s4;
            var t0 = (p2 +% p3) *% 4096;
            var t1 = (p2 -% p3) *% 4096;
            const x0 = t0 +% t3;
            const x3 = t0 -% t3;
            const x1 = t1 +% t2;
            const x2 = t1 -% t2;
            t0 = s7;
            t1 = s5;
            t2 = s3;
            t3 = s1;
            p3 = t0 +% t2;
            var p4 = t1 +% t3;
            p1 = t0 +% t3;
            p2 = t1 +% t2;
            const p5 = (p3 +% p4) *% f2f(1.175875602);
            t0 = t0 *% f2f(0.298631336);
            t1 = t1 *% f2f(2.053119869);
            t2 = t2 *% f2f(3.072711026);
            t3 = t3 *% f2f(1.501321110);
            p1 = p5 +% p1 *% f2f(-0.899976223);
            p2 = p5 +% p2 *% f2f(-2.562915447);
            p3 = p3 *% f2f(-1.961570560);
            p4 = p4 *% f2f(-0.390180644);
            t3 +%= p1 +% p4;
            t2 +%= p2 +% p3;
            t1 +%= p2 +% p4;
            t0 +%= p1 +% p3;
            return .{ .x0 = x0, .x1 = x1, .x2 = x2, .x3 = x3, .t0 = t0, .t1 = t1, .t2 = t2, .t3 = t3 };
        }
    };
    var v: [64]i32 = undefined;
    // Columns.
    for (0..8) |i| {
        const d = data[i..];
        if (d[8] == 0 and d[16] == 0 and d[24] == 0 and d[32] == 0 and d[40] == 0 and d[48] == 0 and d[56] == 0) {
            const dc = d[0] *% 4;
            for (0..8) |j| v[i + j * 8] = dc;
            continue;
        }
        var p = Pass.of(d[0], d[8], d[16], d[24], d[32], d[40], d[48], d[56]);
        p.x0 +%= 512;
        p.x1 +%= 512;
        p.x2 +%= 512;
        p.x3 +%= 512;
        v[i + 0] = (p.x0 +% p.t3) >> 10;
        v[i + 56] = (p.x0 -% p.t3) >> 10;
        v[i + 8] = (p.x1 +% p.t2) >> 10;
        v[i + 48] = (p.x1 -% p.t2) >> 10;
        v[i + 16] = (p.x2 +% p.t1) >> 10;
        v[i + 40] = (p.x2 -% p.t1) >> 10;
        v[i + 24] = (p.x3 +% p.t0) >> 10;
        v[i + 32] = (p.x3 -% p.t0) >> 10;
    }
    // Rows, scaled back down, and moved from -128..127 to 0..255.
    for (0..8) |i| {
        const r = v[i * 8 ..];
        var p = Pass.of(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
        const bias = 65536 + (128 << 17);
        p.x0 +%= bias;
        p.x1 +%= bias;
        p.x2 +%= bias;
        p.x3 +%= bias;
        const o = out[i * stride ..];
        o[0] = clamp((p.x0 +% p.t3) >> 17);
        o[7] = clamp((p.x0 -% p.t3) >> 17);
        o[1] = clamp((p.x1 +% p.t2) >> 17);
        o[6] = clamp((p.x1 -% p.t2) >> 17);
        o[2] = clamp((p.x2 +% p.t1) >> 17);
        o[5] = clamp((p.x2 -% p.t1) >> 17);
        o[3] = clamp((p.x3 +% p.t0) >> 17);
        o[4] = clamp((p.x3 -% p.t0) >> 17);
    }
}

const testing = std.testing;

/// How far a decoded gradient (as the fixtures were made: red across,
/// green down, blue the opposite of red) is from what it should be.
fn expectGradient(name: []const u8, data: []const u8, grey: bool, max_err: u32, mean_err: u32) !void {
    const img = try decode(testing.allocator, data);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqual(@as(u32, 67), img.width);
    try testing.expectEqual(@as(u32, 45), img.height);
    var worst: u32 = 0;
    var total: u64 = 0;
    for (0..45) |y| for (0..67) |x| {
        const r: i32 = @intCast(x * 255 / 66);
        const g: i32 = @intCast(y * 255 / 44);
        const b: i32 = 255 - r;
        const want: [3]i32 = if (grey) blk: {
            const l = @divTrunc(r * 299 + g * 587 + b * 114 + 500, 1000);
            break :blk .{ l, l, l };
        } else .{ r, g, b };
        const px = img.pixels[y * 67 + x];
        try testing.expectEqual(@as(u32, 0xff), px >> 24);
        const got = [3]i32{ @intCast(px >> 16 & 0xff), @intCast(px >> 8 & 0xff), @intCast(px & 0xff) };
        for (want, got) |w, gv| {
            const e: u32 = @abs(w - gv);
            worst = @max(worst, e);
            total += e;
        }
    };
    const mean: u32 = @intCast(total / (67 * 45 * 3));
    if (worst > max_err or mean > mean_err) {
        std.debug.print("{s}: worst {d}, mean {d}\n", .{ name, worst, mean });
        return error.TestUnexpectedResult;
    }
}

test "baseline, progressive, subsampled, grey, CMYK and restart-marked JPEGs decode" {
    try expectGradient("4:4:4", @embedFile("testdata/gradient_444.jpg"), false, 8, 2);
    try expectGradient("4:2:0", @embedFile("testdata/gradient_420.jpg"), false, 16, 3);
    try expectGradient("progressive", @embedFile("testdata/gradient_progressive.jpg"), false, 16, 3);
    try expectGradient("restart", @embedFile("testdata/gradient_restart.jpg"), false, 16, 3);
    try expectGradient("grey", @embedFile("testdata/gradient_grey.jpg"), true, 8, 2);
    try expectGradient("CMYK", @embedFile("testdata/gradient_cmyk.jpg"), false, 8, 2);
}

test "broken JPEGs are refused, and none crash" {
    try testing.expectError(error.Malformed, decode(testing.allocator, "not a jpeg"));
    const good = @embedFile("testdata/gradient_progressive.jpg");
    // Cut short anywhere, or with bytes changed: an error or a picture,
    // never a crash.
    var buf: [good.len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    for (0..300) |i| {
        @memcpy(&buf, good);
        const len = if (i % 3 == 0) prng.random().uintLessThan(usize, good.len) else good.len;
        if (i % 3 != 0) for (0..4) |_| {
            buf[prng.random().uintLessThan(usize, good.len)] = prng.random().int(u8);
        };
        if (decode(testing.allocator, buf[0..len])) |img| testing.allocator.free(img.pixels) else |_| {}
    }
}

test "a JPEG is turned as its EXIF orientation says" {
    const plain = try decode(testing.allocator, @embedFile("testdata/gradient_444.jpg"));
    defer testing.allocator.free(plain.pixels);
    inline for (.{ 3, 5, 6, 8 }) |o| {
        const img = try decode(testing.allocator, @embedFile(std.fmt.comptimePrint("testdata/gradient_exif{d}.jpg", .{o})));
        defer testing.allocator.free(img.pixels);
        const want = try orient(testing.allocator, plain, o);
        defer testing.allocator.free(want.pixels);
        try testing.expectEqual(want.width, img.width);
        try testing.expectEqualSlices(u32, want.pixels, img.pixels);
    }
    // Turned a quarter clockwise: the top left corner (red's least, green's
    // least) is at the top right.
    const six = try decode(testing.allocator, @embedFile("testdata/gradient_exif6.jpg"));
    defer testing.allocator.free(six.pixels);
    try testing.expectEqual(@as(u32, 45), six.width);
    try testing.expectEqual(@as(u32, 67), six.height);
    const corner = six.pixels[44];
    try testing.expect((corner >> 16) & 0xff < 16 and (corner >> 8) & 0xff < 16);
}
