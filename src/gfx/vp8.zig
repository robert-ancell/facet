//! Decoding a VP8 key frame (RFC 6386), as lossy WebP images hold: the
//! boolean-coded modes and coefficients, intra prediction, the inverse
//! transforms, the loop filter, then YUV to RGB (BT.601, as libwebp does,
//! with chroma upsampled smoothly). It follows the RFC's reference decoder.

const std = @import("std");
const png = @import("png.zig");
const tables = @import("vp8_tables.zig");

pub const Error = png.Error;
pub const Decoded = png.Decoded;

const BoolDecoder = struct {
    data: []const u8,
    at: usize = 0,
    value: u32 = 0,
    range: u32 = 255,
    bit_count: u4 = 0,

    fn init(data: []const u8) BoolDecoder {
        var d: BoolDecoder = .{ .data = data };
        if (data.len >= 2) {
            d.value = @as(u32, data[0]) << 8 | data[1];
            d.at = 2;
        } else d.at = data.len;
        return d;
    }

    fn get(d: *BoolDecoder, prob: u8) bool {
        const split = 1 + (((d.range - 1) * prob) >> 8);
        const big = split << 8;
        var one = false;
        if (d.value >= big) {
            one = true;
            d.range -= split;
            d.value -= big;
        } else d.range = split;
        while (d.range < 128) {
            d.value <<= 1;
            d.range <<= 1;
            d.bit_count += 1;
            if (d.bit_count == 8) {
                d.bit_count = 0;
                if (d.at < d.data.len) {
                    d.value |= d.data[d.at];
                    d.at += 1;
                }
            }
        }
        return one;
    }

    fn bit(d: *BoolDecoder) bool {
        return d.get(128);
    }

    fn uint(d: *BoolDecoder, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = v << 1 | @intFromBool(d.bit());
        return v;
    }

    fn int(d: *BoolDecoder, n: u5) i32 {
        const v: i32 = @intCast(d.uint(n));
        return if (d.bit()) -v else v;
    }

    fn maybeInt(d: *BoolDecoder, n: u5) i32 {
        return if (d.bit()) d.int(n) else 0;
    }

    /// A tree's leaf: interior nodes are indexes, leaves their negation.
    fn tree(d: *BoolDecoder, t: []const i8, probs: []const u8) u8 {
        var i: i8 = 0;
        while (true) {
            i = t[@intCast(i + @intFromBool(d.get(probs[@intCast(i >> 1)])))];
            if (i <= 0) return @intCast(-i);
        }
    }
};

const dc_pred = 0;
const v_pred = 1;
const h_pred = 2;
const tm_pred = 3;
const b_pred = 4;

const kf_y_mode_tree = [_]i8{ -b_pred, 2, 4, 6, -dc_pred, -v_pred, -h_pred, -tm_pred };
const kf_y_mode_probs = [_]u8{ 145, 156, 163, 128 };
const uv_mode_tree = [_]i8{ -dc_pred, 2, -v_pred, 4, -h_pred, -tm_pred };
const kf_uv_mode_probs = [_]u8{ 142, 114, 183 };

// Subblock modes.
const b_dc = 0;
const b_tm = 1;
const b_ve = 2;
const b_he = 3;
const b_ld = 4;
const b_rd = 5;
const b_vr = 6;
const b_vl = 7;
const b_hd = 8;
const b_hu = 9;
const b_mode_tree = [_]i8{ -b_dc, 2, -b_tm, 4, -b_ve, 6, 8, 12, -b_he, 10, -b_rd, -b_vr, -b_ld, 14, -b_vl, 16, -b_hd, -b_hu };

const Macroblock = struct {
    y_mode: u8 = dc_pred,
    uv_mode: u8 = dc_pred,
    b_modes: [16]u8 = @splat(b_dc),
    segment: u2 = 0,
    skip: bool = false,
    /// Any non-zero coefficients (for the loop filter).
    coeffs: bool = false,
};

/// A plane with a border: above and left of (0, 0), and to the right.
const Plane = struct {
    pixels: []u8,
    stride: usize,
    border: usize,

    fn at(p: Plane, x: usize, y: usize) usize {
        return (y + p.border) * p.stride + x + p.border;
    }
};

const Header = struct {
    segmentation: bool = false,
    update_map: bool = false,
    abs: bool = false,
    seg_quant: [4]i32 = @splat(0),
    seg_lf: [4]i32 = @splat(0),
    seg_probs: [3]u8 = @splat(255),
    simple_filter: bool = false,
    filter_level: i32 = 0,
    sharpness: i32 = 0,
    lf_deltas: bool = false,
    ref_delta: [4]i32 = @splat(0),
    mode_delta: [4]i32 = @splat(0),
    skip_enabled: bool = false,
    skip_prob: u8 = 0,
    /// Dequantization factors by segment: Y1, Y2 and UV, DC then AC.
    dq: [4][3][2]i32 = undefined,
    probs: [4][8][3][11]u8 = undefined,
};

pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    return decodeRegion(gpa, data, null);
}

/// Decodes part of a VP8 key frame (all of it if `region` is null): its
/// macroblocks down to the region's last row (and one more, which the
/// loop filter and chroma upsampling reach into), and only the region
/// turned to RGB.
pub fn decodeRegion(gpa: std.mem.Allocator, data: []const u8, region: ?png.Region) Error!Decoded {
    if (data.len < 10) return error.Malformed;
    const tag = @as(u32, data[0]) | @as(u32, data[1]) << 8 | @as(u32, data[2]) << 16;
    if (tag & 1 != 0) return error.Unsupported; // Not a key frame.
    const part0 = (tag >> 5) & 0x7ffff;
    if (data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) return error.Malformed;
    const width: u32 = std.mem.readInt(u16, data[6..8], .little) & 0x3fff;
    const height: u32 = std.mem.readInt(u16, data[8..10], .little) & 0x3fff;
    if (width == 0 or height == 0) return error.Malformed;
    const reg = try png.Region.within(region, width, height);
    if (part0 > data.len - 10) return error.Malformed;
    var d = BoolDecoder.init(data[10..][0..part0]);
    var h: Header = .{};
    _ = d.uint(2); // Colour space and clamping.
    // Segmentation.
    h.segmentation = d.bit();
    if (h.segmentation) {
        h.update_map = d.bit();
        if (d.bit()) {
            h.abs = d.bit();
            for (&h.seg_quant) |*q| q.* = d.maybeInt(7);
            for (&h.seg_lf) |*l| l.* = d.maybeInt(6);
        }
        if (h.update_map) for (&h.seg_probs) |*p| {
            p.* = if (d.bit()) @intCast(d.uint(8)) else 255;
        };
    }
    // The loop filter.
    h.simple_filter = d.bit();
    h.filter_level = @intCast(d.uint(6));
    h.sharpness = @intCast(d.uint(3));
    h.lf_deltas = d.bit();
    if (h.lf_deltas and d.bit()) {
        for (&h.ref_delta) |*r| r.* = d.maybeInt(6);
        for (&h.mode_delta) |*m| m.* = d.maybeInt(6);
    }
    // The token partitions.
    const partitions = @as(usize, 1) << @intCast(d.uint(2));
    var rest = data[10 + part0 ..];
    if (rest.len < 3 * (partitions - 1)) return error.Malformed;
    var parts: [8]BoolDecoder = undefined;
    const sizes = rest[0 .. 3 * (partitions - 1)];
    rest = rest[3 * (partitions - 1) ..];
    for (0..partitions) |i| {
        const size: usize = if (i + 1 < partitions) @as(usize, sizes[i * 3]) | @as(usize, sizes[i * 3 + 1]) << 8 | @as(usize, sizes[i * 3 + 2]) << 16 else rest.len;
        if (size > rest.len) return error.Malformed;
        parts[i] = BoolDecoder.init(rest[0..size]);
        rest = rest[size..];
    }
    // Quantizers.
    const q_index: i32 = @intCast(d.uint(7));
    const y1_dc = d.maybeInt(4);
    const y2_dc = d.maybeInt(4);
    const y2_ac = d.maybeInt(4);
    const uv_dc = d.maybeInt(4);
    const uv_ac = d.maybeInt(4);
    for (0..4) |s| {
        var q = q_index;
        if (h.segmentation) q = if (h.abs) h.seg_quant[s] else q + h.seg_quant[s];
        h.dq[s][0] = .{ dcQ(q + y1_dc), acQ(q) };
        h.dq[s][1] = .{ dcQ(q + y2_dc) * 2, @max(8, @divTrunc(acQ(q + y2_ac) * 155, 100)) };
        h.dq[s][2] = .{ @min(132, dcQ(q + uv_dc)), acQ(q + uv_ac) };
    }
    _ = d.bit(); // Refresh the entropy probabilities.
    // Coefficient probabilities, updated from the defaults.
    for (0..4) |i| for (0..8) |j| for (0..3) |k| for (0..11) |l| {
        const n = ((i * 8 + j) * 3 + k) * 11 + l;
        h.probs[i][j][k][l] = if (d.get(tables.coeff_update_probs[n])) @intCast(d.uint(8)) else tables.default_coeff_probs[n];
    };
    h.skip_enabled = d.bit();
    if (h.skip_enabled) h.skip_prob = @intCast(d.uint(8));

    const mb_cols = (width + 15) / 16;
    const mb_rows = @min((height + 15) / 16, (reg.y1() + 15) / 16 + 1);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const mbs = try a.alloc(Macroblock, mb_cols * mb_rows);
    @memset(mbs, .{});
    const y_plane = try newPlane(a, mb_cols * 16, mb_rows * 16, 16);
    const u_plane = try newPlane(a, mb_cols * 8, mb_rows * 8, 8);
    const v_plane = try newPlane(a, mb_cols * 8, mb_rows * 8, 8);
    const above_ctx = try a.alloc([9]u8, mb_cols);
    @memset(above_ctx, @splat(0));
    const outside: Macroblock = .{};

    for (0..mb_rows) |my| {
        var left_ctx: [9]u8 = @splat(0);
        const tokens = &parts[my % partitions];
        for (0..mb_cols) |mx| {
            const mb = &mbs[my * mb_cols + mx];
            // The macroblock's header.
            if (h.update_map) mb.segment = @intCast(if (d.get(h.seg_probs[0])) 2 + @as(u8, @intFromBool(d.get(h.seg_probs[2]))) else @as(u8, @intFromBool(d.get(h.seg_probs[1]))));
            if (h.skip_enabled) mb.skip = d.get(h.skip_prob);
            mb.y_mode = d.tree(&kf_y_mode_tree, &kf_y_mode_probs);
            if (mb.y_mode == b_pred) {
                const above = if (my > 0) &mbs[(my - 1) * mb_cols + mx] else &outside;
                const left = if (mx > 0) &mbs[my * mb_cols + mx - 1] else &outside;
                for (0..16) |i| {
                    const am = if (i < 4) blockMode(above, i + 12) else mb.b_modes[i - 4];
                    const lm = if (i & 3 == 0) blockMode(left, i + 3) else mb.b_modes[i - 1];
                    mb.b_modes[i] = d.tree(&b_mode_tree, tables.kf_bmode_probs[(@as(usize, am) * 10 + lm) * 9 ..][0..9]);
                }
            }
            mb.uv_mode = d.tree(&uv_mode_tree, &kf_uv_mode_probs);
            // Its coefficients.
            var coeffs: [25][16]i16 = @splat(@splat(0));
            if (mb.skip) {
                const keep_y2 = above_ctx[mx][8];
                const keep_y2_left = left_ctx[8];
                above_ctx[mx] = @splat(0);
                left_ctx = @splat(0);
                if (mb.y_mode == b_pred) {
                    above_ctx[mx][8] = keep_y2;
                    left_ctx[8] = keep_y2_left;
                }
            } else {
                mb.coeffs = decodeTokens(tokens, &h, mb, &left_ctx, &above_ctx[mx], &coeffs);
            }
            reconstruct(mb, mx, my, &coeffs, y_plane, u_plane, v_plane);
        }
        // Past the right edge, for the next row's above-right pixels: the
        // last pixel of this row's bottom line.
        const last = y_plane.at(mb_cols * 16 - 1, my * 16 + 15);
        @memset(y_plane.pixels[last + 1 ..][0..4], y_plane.pixels[last]);
    }
    if (h.filter_level > 0) loopFilter(&h, mbs, mb_cols, mb_rows, y_plane, u_plane, v_plane);
    const out = try gpa.alloc(u32, @as(usize, reg.w) * reg.h);
    toRgb(out, reg, width, height, y_plane, u_plane, v_plane);
    return .{ .pixels = out, .width = reg.w, .height = reg.h };
}

fn dcQ(q: i32) i32 {
    return tables.dc_q[@intCast(std.math.clamp(q, 0, 127))];
}

fn acQ(q: i32) i32 {
    return tables.ac_q[@intCast(std.math.clamp(q, 0, 127))];
}

/// A neighbouring macroblock's subblock mode `b`, for context: its own, or
/// what its whole-block mode stands for.
fn blockMode(mb: *const Macroblock, b: usize) u8 {
    return switch (mb.y_mode) {
        dc_pred => b_dc,
        v_pred => b_ve,
        h_pred => b_he,
        tm_pred => b_tm,
        else => mb.b_modes[b],
    };
}

/// A plane `w` by `h`, the row above it 127, the column left of it 129.
fn newPlane(a: std.mem.Allocator, w: usize, h: usize, border: usize) !Plane {
    const stride = w + border * 2;
    const p: Plane = .{ .pixels = try a.alloc(u8, stride * (h + border)), .stride = stride, .border = border };
    @memset(p.pixels, 0);
    for (0..h) |y| p.pixels[(y + border) * stride + border - 1] = 129;
    @memset(p.pixels[(border - 1) * stride + border - 1 ..][0 .. w + border + 1], 127);
    return p;
}

const left_ctx_index = [25]u8{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8 };
const above_ctx_index = [25]u8{ 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 4, 5, 6, 7, 6, 7, 8 };

/// A macroblock's coefficients, dequantized; whether any are non-zero.
fn decodeTokens(d: *BoolDecoder, h: *const Header, mb: *const Macroblock, left: *[9]u8, above: *[9]u8, out: *[25][16]i16) bool {
    const dq = &h.dq[mb.segment];
    var any = false;
    const has_y2 = mb.y_mode != b_pred;
    if (has_y2) {
        const ctx = left[8] + above[8];
        const nz = decodeBlock(d, &h.probs[1], ctx, 0, dq[1], &out[24]);
        left[8] = @intFromBool(nz);
        above[8] = @intFromBool(nz);
        any = any or nz;
    }
    const y_type: usize = if (has_y2) 0 else 3;
    for (0..24) |i| {
        const ctx = left[left_ctx_index[i]] + above[above_ctx_index[i]];
        const nz = if (i < 16)
            decodeBlock(d, &h.probs[y_type], ctx, if (has_y2) 1 else 0, dq[0], &out[i])
        else
            decodeBlock(d, &h.probs[2], ctx, 0, dq[2], &out[i]);
        left[left_ctx_index[i]] = @intFromBool(nz);
        above[above_ctx_index[i]] = @intFromBool(nz);
        any = any or nz;
    }
    return any;
}

/// One block's coefficients (from `first`), in natural order; whether any
/// tokens were read.
fn decodeBlock(d: *BoolDecoder, probs: *const [8][3][11]u8, ctx: u8, first: usize, dq: [2]i32, out: *[16]i16) bool {
    var c = first;
    var p = &probs[tables.coeff_bands[c]][ctx];
    if (!d.get(p[0])) return false;
    while (true) {
        if (!d.get(p[1])) {
            // A zero: no end of block can follow it.
            c += 1;
            if (c == 16) return true;
            p = &probs[tables.coeff_bands[c]][0];
            continue;
        }
        var v: i32 = undefined;
        var next_ctx: u8 = 2;
        if (!d.get(p[2])) {
            v = 1;
            next_ctx = 1;
        } else if (!d.get(p[3])) {
            v = if (!d.get(p[4])) 2 else if (!d.get(p[5])) 3 else 4;
        } else if (!d.get(p[6])) {
            v = if (!d.get(p[7])) 5 + extra(d, &.{159}) else 7 + extra(d, &.{ 165, 145 });
        } else if (!d.get(p[8])) {
            v = if (!d.get(p[9])) 11 + extra(d, &.{ 173, 148, 140 }) else 19 + extra(d, &.{ 176, 155, 140, 135 });
        } else {
            v = if (!d.get(p[10])) 35 + extra(d, &.{ 180, 157, 141, 134, 130 }) else 67 + extra(d, tables.pcat6[0..11]);
        }
        if (d.bit()) v = -v;
        out[tables.zigzag[c]] = @truncate(v *% dq[@intFromBool(c > 0)]);
        c += 1;
        if (c == 16) return true;
        p = &probs[tables.coeff_bands[c]][next_ctx];
        if (!d.get(p[0])) return true;
    }
}

/// A token's extra bits, most significant first.
fn extra(d: *BoolDecoder, probs: []const u8) i32 {
    var v: i32 = 0;
    for (probs) |p| v = v << 1 | @intFromBool(d.get(p));
    return v;
}

/// Predicts a macroblock and adds its residue.
fn reconstruct(mb: *const Macroblock, mx: usize, my: usize, coeffs: *[25][16]i16, y: Plane, u: Plane, v: Plane) void {
    const yi = y.at(mx * 16, my * 16);
    if (mb.y_mode == b_pred) {
        // The above-right pixels of the right column's subblocks below the
        // first: those of the first (above the macroblock to the right).
        const ar = yi + 16 - y.stride;
        for ([_]usize{ 3, 7, 11 }) |r| @memcpy(y.pixels[yi + 16 + r * y.stride ..][0..4], y.pixels[ar..][0..4]);
        for (0..16) |i| {
            const bi = yi + (i / 4) * 4 * y.stride + (i % 4) * 4;
            predictSubblock(y.pixels, bi, y.stride, mb.b_modes[i]);
            idctAdd(y.pixels, bi, y.stride, &coeffs[i]);
        }
    } else {
        predictBlock(y.pixels, yi, y.stride, 16, mb.y_mode, mx == 0, my == 0);
        // The DCs, from the second-order block.
        const dcs = walsh(&coeffs[24]);
        for (0..16) |i| {
            coeffs[i][0] = dcs[i];
            idctAdd(y.pixels, yi + (i / 4) * 4 * y.stride + (i % 4) * 4, y.stride, &coeffs[i]);
        }
    }
    for ([_]Plane{ u, v }, 0..) |p, k| {
        const pi = p.at(mx * 8, my * 8);
        predictBlock(p.pixels, pi, p.stride, 8, mb.uv_mode, mx == 0, my == 0);
        for (0..4) |i| idctAdd(p.pixels, pi + (i / 2) * 4 * p.stride + (i % 2) * 4, p.stride, &coeffs[16 + k * 4 + i]);
    }
}

fn clamp255(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// A 16×16 or 8×8 block's prediction; DC from only the edges inside the
/// frame (128 with none).
fn predictBlock(px: []u8, at: usize, stride: usize, n: usize, mode: u8, left_edge: bool, top_edge: bool) void {
    const above = at - stride;
    switch (mode) {
        dc_pred => {
            var sum: u32 = 0;
            var count: u32 = 0;
            if (!top_edge) {
                for (0..n) |i| sum += px[above + i];
                count += @intCast(n);
            }
            if (!left_edge) {
                for (0..n) |i| sum += px[at + i * stride - 1];
                count += @intCast(n);
            }
            const dc: u8 = if (count == 0) 128 else @intCast((sum + count / 2) / count);
            for (0..n) |r| @memset(px[at + r * stride ..][0..n], dc);
        },
        v_pred => for (0..n) |r| @memcpy(px[at + r * stride ..][0..n], px[above..][0..n]),
        h_pred => for (0..n) |r| @memset(px[at + r * stride ..][0..n], px[at + r * stride - 1]),
        else => {
            const corner: i32 = px[above - 1];
            for (0..n) |r| {
                const l: i32 = px[at + r * stride - 1];
                for (0..n) |c| px[at + r * stride + c] = clamp255(l + px[above + c] - corner);
            }
        },
    }
}

/// A 4×4 subblock's prediction, from the pixels around it (and above
/// right).
fn predictSubblock(px: []u8, at: usize, stride: usize, mode: u8) void {
    const s = stride;
    // Above, from the above-left (A[0]) to the above-right (A[8]); left,
    // from the above-left (L[0]) down.
    var A: [9]i32 = undefined;
    for (0..9) |i| A[i] = px[at - s - 1 + i];
    var L: [5]i32 = undefined;
    for (0..5) |i| L[i] = px[at + i * s - s - 1];
    const put = struct {
        fn f(p: []u8, a: usize, st: usize, x: usize, y: usize, v: i32) void {
            p[a + y * st + x] = @intCast(v);
        }
    }.f;
    const avg3 = struct {
        fn f(x: i32, y: i32, z: i32) i32 {
            return (x + 2 * y + z + 2) >> 2;
        }
    }.f;
    const avg2 = struct {
        fn f(x: i32, y: i32) i32 {
            return (x + y + 1) >> 1;
        }
    }.f;
    // Above and left, without the corner.
    const t = A[1..];
    const l = L[1..];
    const c = A[0];
    switch (mode) {
        b_dc => {
            var sum: i32 = 4;
            for (0..4) |i| sum += t[i] + l[i];
            for (0..4) |y| for (0..4) |x| put(px, at, s, x, y, sum >> 3);
        },
        b_tm => for (0..4) |y| for (0..4) |x| put(px, at, s, x, y, clamp255(l[y] + t[x] - c)),
        b_ve => for (0..4) |x| {
            const v = avg3(if (x == 0) c else t[x - 1], t[x], t[x + 1]);
            for (0..4) |y| put(px, at, s, x, y, v);
        },
        b_he => for (0..4) |y| {
            const v = avg3(if (y == 0) c else l[y - 1], l[y], if (y == 3) l[3] else l[y + 1]);
            for (0..4) |x| put(px, at, s, x, y, v);
        },
        b_ld => for (0..4) |y| for (0..4) |x| {
            const i = x + y;
            put(px, at, s, x, y, if (i == 6) avg3(t[6], t[7], t[7]) else avg3(t[i], t[i + 1], t[i + 2]));
        },
        b_rd => {
            // The edge from the bottom left, round the corner, to the right.
            const e = [9]i32{ l[3], l[2], l[1], l[0], c, t[0], t[1], t[2], t[3] };
            for (0..4) |y| for (0..4) |x| {
                const i = 3 - y + x;
                put(px, at, s, x, y, avg3(e[i], e[i + 1], e[i + 2]));
            };
        },
        b_vr => {
            const e = [9]i32{ l[3], l[2], l[1], l[0], c, t[0], t[1], t[2], t[3] };
            const vals = [4][4]i32{
                .{ avg2(c, t[0]), avg2(t[0], t[1]), avg2(t[1], t[2]), avg2(t[2], t[3]) },
                .{ avg3(l[0], c, t[0]), avg3(c, t[0], t[1]), avg3(t[0], t[1], t[2]), avg3(t[1], t[2], t[3]) },
                .{ avg3(l[1], l[0], c), avg2(c, t[0]), avg2(t[0], t[1]), avg2(t[1], t[2]) },
                .{ avg3(l[2], l[1], l[0]), avg3(l[0], c, t[0]), avg3(c, t[0], t[1]), avg3(t[0], t[1], t[2]) },
            };
            _ = e;
            for (0..4) |y| for (0..4) |x| put(px, at, s, x, y, vals[y][x]);
        },
        b_vl => {
            const vals = [4][4]i32{
                .{ avg2(t[0], t[1]), avg2(t[1], t[2]), avg2(t[2], t[3]), avg2(t[3], t[4]) },
                .{ avg3(t[0], t[1], t[2]), avg3(t[1], t[2], t[3]), avg3(t[2], t[3], t[4]), avg3(t[3], t[4], t[5]) },
                .{ avg2(t[1], t[2]), avg2(t[2], t[3]), avg2(t[3], t[4]), avg3(t[4], t[5], t[6]) },
                .{ avg3(t[1], t[2], t[3]), avg3(t[2], t[3], t[4]), avg3(t[3], t[4], t[5]), avg3(t[5], t[6], t[7]) },
            };
            for (0..4) |y| for (0..4) |x| put(px, at, s, x, y, vals[y][x]);
        },
        b_hd => {
            const vals = [4][4]i32{
                .{ avg2(l[0], c), avg3(l[0], c, t[0]), avg3(c, t[0], t[1]), avg3(t[0], t[1], t[2]) },
                .{ avg2(l[1], l[0]), avg3(l[1], l[0], c), avg2(l[0], c), avg3(l[0], c, t[0]) },
                .{ avg2(l[2], l[1]), avg3(l[2], l[1], l[0]), avg2(l[1], l[0]), avg3(l[1], l[0], c) },
                .{ avg2(l[3], l[2]), avg3(l[3], l[2], l[1]), avg2(l[2], l[1]), avg3(l[2], l[1], l[0]) },
            };
            for (0..4) |y| for (0..4) |x| put(px, at, s, x, y, vals[y][x]);
        },
        else => {
            const vals = [4][4]i32{
                .{ avg2(l[0], l[1]), avg3(l[0], l[1], l[2]), avg2(l[1], l[2]), avg3(l[1], l[2], l[3]) },
                .{ avg2(l[1], l[2]), avg3(l[1], l[2], l[3]), avg2(l[2], l[3]), avg3(l[2], l[3], l[3]) },
                .{ avg2(l[2], l[3]), avg3(l[2], l[3], l[3]), l[3], l[3] },
                .{ l[3], l[3], l[3], l[3] },
            };
            for (0..4) |y| for (0..4) |x| put(px, at, s, x, y, vals[y][x]);
        },
    }
}

/// The inverse Walsh-Hadamard transform of the second-order block.
fn walsh(in: *const [16]i16) [16]i16 {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a1 = @as(i32, in[i]) + in[12 + i];
        const b1 = @as(i32, in[4 + i]) + in[8 + i];
        const c1 = @as(i32, in[4 + i]) - in[8 + i];
        const d1 = @as(i32, in[i]) - in[12 + i];
        tmp[i] = a1 + b1;
        tmp[4 + i] = c1 + d1;
        tmp[8 + i] = a1 - b1;
        tmp[12 + i] = d1 - c1;
    }
    var out: [16]i16 = undefined;
    for (0..4) |i| {
        const r = tmp[i * 4 ..][0..4];
        const a1 = r[0] + r[3];
        const b1 = r[1] + r[2];
        const c1 = r[1] - r[2];
        const d1 = r[0] - r[3];
        out[i * 4 + 0] = @truncate((a1 + b1 + 3) >> 3);
        out[i * 4 + 1] = @truncate((c1 + d1 + 3) >> 3);
        out[i * 4 + 2] = @truncate((a1 - b1 + 3) >> 3);
        out[i * 4 + 3] = @truncate((d1 - c1 + 3) >> 3);
    }
    return out;
}

/// Adds a 4×4 block's inverse DCT to the prediction there.
fn idctAdd(px: []u8, at: usize, stride: usize, in: *const [16]i16) void {
    const c1k = 20091;
    const s1k = 35468;
    var tmp: [16]i16 = undefined;
    for (0..4) |i| {
        const ip0: i32 = in[i];
        const ip4: i32 = in[4 + i];
        const ip8: i32 = in[8 + i];
        const ip12: i32 = in[12 + i];
        const a1 = ip0 + ip8;
        const b1 = ip0 - ip8;
        const c1 = ((ip4 * s1k) >> 16) - (ip12 + ((ip12 * c1k) >> 16));
        const d1 = (ip4 + ((ip4 * c1k) >> 16)) + ((ip12 * s1k) >> 16);
        tmp[i] = @truncate(a1 + d1);
        tmp[12 + i] = @truncate(a1 - d1);
        tmp[4 + i] = @truncate(b1 + c1);
        tmp[8 + i] = @truncate(b1 - c1);
    }
    for (0..4) |i| {
        const r = tmp[i * 4 ..][0..4];
        const a1 = @as(i32, r[0]) + r[2];
        const b1 = @as(i32, r[0]) - r[2];
        const c1 = ((@as(i32, r[1]) * s1k) >> 16) - (@as(i32, r[3]) + ((@as(i32, r[3]) * c1k) >> 16));
        const d1 = (@as(i32, r[1]) + ((@as(i32, r[1]) * c1k) >> 16)) + ((@as(i32, r[3]) * s1k) >> 16);
        const o = px[at + i * stride ..][0..4];
        o[0] = clamp255(@as(i32, o[0]) + ((a1 + d1 + 4) >> 3));
        o[3] = clamp255(@as(i32, o[3]) + ((a1 - d1 + 4) >> 3));
        o[1] = clamp255(@as(i32, o[1]) + ((b1 + c1 + 4) >> 3));
        o[2] = clamp255(@as(i32, o[2]) + ((b1 - c1 + 4) >> 3));
    }
}

// --- The loop filter ----------------------------------------------------------

fn s8(x: i32) i32 {
    return std.math.clamp(x, -128, 127);
}

const Edge = struct {
    px: []u8,
    at: usize,
    /// From one pixel across the edge to the next.
    step: isize,

    fn get(e: Edge, i: isize) i32 {
        return e.px[@intCast(@as(isize, @intCast(e.at)) + i * e.step)];
    }

    fn set(e: Edge, i: isize, v: i32) void {
        e.px[@intCast(@as(isize, @intCast(e.at)) + i * e.step)] = clamp255(v);
    }
};

fn simpleThreshold(e: Edge, limit: i32) bool {
    return @abs(e.get(-1) - e.get(0)) * 2 + (@abs(e.get(-2) - e.get(1)) >> 1) <= limit;
}

fn normalThreshold(e: Edge, edge_limit: i32, interior: i32) bool {
    if (!simpleThreshold(e, 2 * edge_limit + interior)) return false;
    const I: u32 = @intCast(interior);
    return @abs(e.get(-4) - e.get(-3)) <= I and @abs(e.get(-3) - e.get(-2)) <= I and @abs(e.get(-2) - e.get(-1)) <= I and
        @abs(e.get(3) - e.get(2)) <= I and @abs(e.get(2) - e.get(1)) <= I and @abs(e.get(1) - e.get(0)) <= I;
}

fn highVariance(e: Edge, threshold: i32) bool {
    return @abs(e.get(-2) - e.get(-1)) > threshold or @abs(e.get(1) - e.get(0)) > threshold;
}

fn filterCommon(e: Edge, outer: bool) void {
    const p1 = e.get(-2);
    const p0 = e.get(-1);
    const q0 = e.get(0);
    const q1 = e.get(1);
    var a = 3 * (q0 - p0);
    if (outer) a += s8(p1 - q1);
    a = s8(a);
    const f1 = @min(a + 4, 127) >> 3;
    const f2 = @min(a + 3, 127) >> 3;
    e.set(-1, p0 + f2);
    e.set(0, q0 - f1);
    if (!outer) {
        const a2 = (f1 + 1) >> 1;
        e.set(-2, p1 + a2);
        e.set(1, q1 - a2);
    }
}

fn filterMbEdge(e: Edge) void {
    const p2 = e.get(-3);
    const p1 = e.get(-2);
    const p0 = e.get(-1);
    const q0 = e.get(0);
    const q1 = e.get(1);
    const q2 = e.get(2);
    const w = s8(s8(p1 - q1) + 3 * (q0 - p0));
    var a = (27 * w + 63) >> 7;
    e.set(-1, p0 + a);
    e.set(0, q0 - a);
    a = (18 * w + 63) >> 7;
    e.set(-2, p1 + a);
    e.set(1, q1 - a);
    a = (9 * w + 63) >> 7;
    e.set(-3, p2 + a);
    e.set(2, q2 - a);
}

/// Filters `len` segments across an edge at `at`, `along` apart, each
/// `step` from one pixel to the next across it.
fn filterEdge(px: []u8, at: usize, along: usize, step: isize, len: usize, mb_edge: bool, simple: bool, edge_limit: i32, interior: i32, hev: i32) void {
    for (0..len) |i| {
        const e: Edge = .{ .px = px, .at = at + i * along, .step = step };
        if (simple) {
            if (simpleThreshold(e, edge_limit)) filterCommon(e, true);
        } else if (normalThreshold(e, edge_limit, interior)) {
            if (mb_edge) {
                if (highVariance(e, hev)) filterCommon(e, true) else filterMbEdge(e);
            } else filterCommon(e, highVariance(e, hev));
        }
    }
}

fn loopFilter(h: *const Header, mbs: []const Macroblock, cols: usize, rows: usize, y: Plane, u: Plane, v: Plane) void {
    for (0..rows) |my| for (0..cols) |mx| {
        const mb = &mbs[my * cols + mx];
        var level = h.filter_level;
        if (h.segmentation) level = if (h.abs) h.seg_lf[mb.segment] else level + h.seg_lf[mb.segment];
        level = std.math.clamp(level, 0, 63);
        if (h.lf_deltas) {
            level += h.ref_delta[0];
            if (mb.y_mode == b_pred) level += h.mode_delta[0];
        }
        level = std.math.clamp(level, 0, 63);
        if (level == 0) continue;
        var interior = level;
        if (h.sharpness > 0) {
            interior >>= if (h.sharpness > 4) 2 else 1;
            interior = @min(interior, 9 - h.sharpness);
        }
        interior = @max(interior, 1);
        const hev: i32 = @as(i32, @intFromBool(level >= 15)) + @intFromBool(level >= 40);
        const inner = mb.coeffs or mb.y_mode == b_pred;
        const ys: isize = @intCast(y.stride);
        const yi = y.at(mx * 16, my * 16);
        if (h.simple_filter) {
            const mb_limit = (level + 2) * 2 + interior;
            const b_limit = level * 2 + interior;
            if (mx > 0) filterEdge(y.pixels, yi, y.stride, 1, 16, true, true, mb_limit, 0, 0);
            if (inner) for ([_]usize{ 4, 8, 12 }) |o| filterEdge(y.pixels, yi + o, y.stride, 1, 16, false, true, b_limit, 0, 0);
            if (my > 0) filterEdge(y.pixels, yi, 1, ys, 16, true, true, mb_limit, 0, 0);
            if (inner) for ([_]usize{ 4, 8, 12 }) |o| filterEdge(y.pixels, yi + o * y.stride, 1, ys, 16, false, true, b_limit, 0, 0);
            continue;
        }
        const ui = u.at(mx * 8, my * 8);
        const vi = v.at(mx * 8, my * 8);
        const cs: isize = @intCast(u.stride);
        if (mx > 0) {
            filterEdge(y.pixels, yi, y.stride, 1, 16, true, false, level + 2, interior, hev);
            filterEdge(u.pixels, ui, u.stride, 1, 8, true, false, level + 2, interior, hev);
            filterEdge(v.pixels, vi, v.stride, 1, 8, true, false, level + 2, interior, hev);
        }
        if (inner) {
            for ([_]usize{ 4, 8, 12 }) |o| filterEdge(y.pixels, yi + o, y.stride, 1, 16, false, false, level, interior, hev);
            filterEdge(u.pixels, ui + 4, u.stride, 1, 8, false, false, level, interior, hev);
            filterEdge(v.pixels, vi + 4, v.stride, 1, 8, false, false, level, interior, hev);
        }
        if (my > 0) {
            filterEdge(y.pixels, yi, 1, ys, 16, true, false, level + 2, interior, hev);
            filterEdge(u.pixels, ui, 1, cs, 8, true, false, level + 2, interior, hev);
            filterEdge(v.pixels, vi, 1, cs, 8, true, false, level + 2, interior, hev);
        }
        if (inner) {
            for ([_]usize{ 4, 8, 12 }) |o| filterEdge(y.pixels, yi + o * y.stride, 1, ys, 16, false, false, level, interior, hev);
            filterEdge(u.pixels, ui + 4 * u.stride, 1, cs, 8, false, false, level, interior, hev);
            filterEdge(v.pixels, vi + 4 * v.stride, 1, cs, 8, false, false, level, interior, hev);
        }
    };
}

// --- To RGB -------------------------------------------------------------------

fn multHi(v: i32, coeff: i32) i32 {
    return (v * coeff) >> 8;
}

fn clip8(v: i32) u8 {
    return if (v & ~@as(i32, 16383) == 0) @intCast(v >> 6) else if (v < 0) 0 else 255;
}

fn rgb(yv: i32, uv: i32, vv: i32) u32 {
    const r = clip8(multHi(yv, 19077) + multHi(vv, 26149) - 14234);
    const g = clip8(multHi(yv, 19077) - multHi(uv, 6419) - multHi(vv, 13320) + 8708);
    const b = clip8(multHi(yv, 19077) + multHi(uv, 33050) - 17685);
    return 0xff000000 | @as(u32, r) << 16 | @as(u32, g) << 8 | b;
}

/// YUV 4:2:0 to pixels, each chroma sample weighted 9:3:3:1 with its
/// neighbours across and down by how near it is (as libwebp's "fancy"
/// upsampling).
/// The pixels of `reg` (of an image `w` by `h`), in `out`.
fn toRgb(out: []u32, reg: png.Region, w: u32, h: u32, y: Plane, u: Plane, v: Plane) void {
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    for (reg.y..reg.y1()) |py| {
        const cy = py / 2;
        // The other chroma row nearest: above for even rows, below for odd.
        const oy = if (py & 1 == 0) (if (cy > 0) cy - 1 else 0) else @min(cy + 1, ch - 1);
        for (reg.x..reg.x1()) |px| {
            const cx = px / 2;
            const ox = if (px & 1 == 0) (if (cx > 0) cx - 1 else 0) else @min(cx + 1, cw - 1);
            const sample = struct {
                fn f(p: Plane, x0: usize, y0: usize, x1: usize, y1: usize) i32 {
                    const a: i32 = p.pixels[p.at(x0, y0)];
                    const b: i32 = p.pixels[p.at(x1, y0)];
                    const c: i32 = p.pixels[p.at(x0, y1)];
                    const d: i32 = p.pixels[p.at(x1, y1)];
                    return (9 * a + 3 * b + 3 * c + d + 8) >> 4;
                }
            }.f;
            const uu = sample(u, cx, cy, ox, oy);
            const vv = sample(v, cx, cy, ox, oy);
            out[(py - reg.y) * reg.w + (px - reg.x)] = rgb(y.pixels[y.at(px, py)], uu, vv);
        }
    }
}
