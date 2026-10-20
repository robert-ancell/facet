//! QrCode: renders an ISO/IEC 18004 QR Code for `text` (in Byte mode, ECC
//! Level L, Versions 1–9, up to 230 bytes) inside a rounded light quiet zone.

const a11y = @import("accessibility.zig");
const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter = @import("painter.zig");

/// Maximum QR version supported (Version 9: 53x53 modules, up to 230 bytes at ECC Level L).
pub const max_version = 9;
pub const max_size = 17 + 4 * max_version;

const VersionSpec = struct {
    data_codewords: u16,
    ec_per_block: u8,
    num_blocks: u8,
    alignment: []const u8,
    version_info: u18 = 0,
};

/// ISO/IEC 18004 Table 9 & Annex D/E specifications for Versions 1–9 at ECC Level L.
const versions = [max_version]VersionSpec{
    .{ .data_codewords = 19, .ec_per_block = 7, .num_blocks = 1, .alignment = &.{} },
    .{ .data_codewords = 34, .ec_per_block = 10, .num_blocks = 1, .alignment = &.{ 6, 18 } },
    .{ .data_codewords = 55, .ec_per_block = 15, .num_blocks = 1, .alignment = &.{ 6, 22 } },
    .{ .data_codewords = 80, .ec_per_block = 20, .num_blocks = 1, .alignment = &.{ 6, 26 } },
    .{ .data_codewords = 108, .ec_per_block = 26, .num_blocks = 1, .alignment = &.{ 6, 30 } },
    .{ .data_codewords = 136, .ec_per_block = 18, .num_blocks = 2, .alignment = &.{ 6, 34 } },
    .{ .data_codewords = 156, .ec_per_block = 20, .num_blocks = 2, .alignment = &.{ 6, 22, 38 }, .version_info = 0x07c94 },
    .{ .data_codewords = 194, .ec_per_block = 24, .num_blocks = 2, .alignment = &.{ 6, 24, 42 }, .version_info = 0x085bc },
    .{ .data_codewords = 232, .ec_per_block = 30, .num_blocks = 2, .alignment = &.{ 6, 26, 46 }, .version_info = 0x09a99 },
};

/// A generated QR Code matrix.
pub const Matrix = struct {
    size: u8 = 21,
    modules: [max_size][max_size]bool = @splat(@splat(false)),
    is_function: [max_size][max_size]bool = @splat(@splat(false)),

    pub fn get(self: *const Matrix, x: usize, y: usize) bool {
        return self.modules[y][x];
    }

    fn setFunction(self: *Matrix, x: usize, y: usize, dark: bool) void {
        self.modules[y][x] = dark;
        self.is_function[y][x] = true;
    }
};

/// Widget that renders a QR code for `text` with a quiet zone.
pub const QrCode = struct {
    text: []const u8,
    size: f32 = 132,

    pub const State = struct {
        hash: u64 = 0,
        len: usize = 0,
        matrix: ?Matrix = null,
        valid: bool = false,
    };

    pub fn accessible(self: *const QrCode, _: *widget.Node) ?a11y.Info {
        return .{ .role = .image, .name = "QR code", .description = self.text, .leaf = true };
    }

    pub fn layout(self: *const QrCode, _: *widget.Node, c: geometry.Constraints) geometry.Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const QrCode, n: *widget.Node, p: *painter.Painter) void {
        const st = n.state(State);
        const h = std.hash.Fnv1a_64.hash(self.text);
        if (!st.valid or st.hash != h or st.len != self.text.len) {
            st.hash = h;
            st.len = self.text.len;
            st.matrix = encode(self.text);
            st.valid = true;
        }
        const matrix = &(st.matrix orelse return);
        const canvas = p.canvas();
        const box_size = @min(n.size.w, n.size.h);
        if (box_size <= 0) return;
        const quiet_modules: usize = 2;
        const total_modules = @as(usize, matrix.size) + quiet_modules * 2;
        const mod_px = @max(1.0, @floor(box_size / @as(f32, @floatFromInt(total_modules))));
        const drawn_size = mod_px * @as(f32, @floatFromInt(total_modules));
        const ox = @floor((n.size.w - drawn_size) * 0.5);
        const oy = @floor((n.size.h - drawn_size) * 0.5);

        canvas.fillRoundedRect(
            .{ .x = ox, .y = oy, .w = drawn_size, .h = drawn_size },
            .all(8),
            gfx.Color.argb(0xffffffff),
        );

        const qx = ox + mod_px * @as(f32, @floatFromInt(quiet_modules));
        const qy = oy + mod_px * @as(f32, @floatFromInt(quiet_modules));
        const dark = gfx.Color.argb(0xff000000);
        const s: usize = matrix.size;
        for (0..s) |y| {
            var x: usize = 0;
            while (x < s) {
                if (!matrix.modules[y][x]) {
                    x += 1;
                    continue;
                }
                var end_x = x + 1;
                while (end_x < s and matrix.modules[y][end_x]) : (end_x += 1) {}
                canvas.fillRect(
                    .{
                        .x = qx + @as(f32, @floatFromInt(x)) * mod_px,
                        .y = qy + @as(f32, @floatFromInt(y)) * mod_px,
                        .w = @as(f32, @floatFromInt(end_x - x)) * mod_px,
                        .h = mod_px,
                    },
                    dark,
                );
                x = end_x;
            }
        }
    }
};

/// Encodes `data` in Byte mode at ECC Level L into a QR Code `Matrix`.
pub fn encode(data: []const u8) ?Matrix {
    const version: u8 = for (versions, 1..) |spec, v| {
        if (data.len + 2 <= spec.data_codewords) break @intCast(v);
    } else return null;
    const spec = versions[version - 1];
    const size: u8 = 17 + 4 * version;

    // 1. Build data codewords in Byte mode (0100, 8-bit length, payload, terminator, padding).
    var data_cw: [232]u8 = @splat(0);
    var bit_len: usize = 0;
    appendBits(&data_cw, &bit_len, 0b0100, 4);
    appendBits(&data_cw, &bit_len, @intCast(data.len), 8);
    for (data) |b| appendBits(&data_cw, &bit_len, b, 8);
    const total_data_bits = @as(usize, spec.data_codewords) * 8;
    const term = @min(@as(usize, 4), total_data_bits - bit_len);
    appendBits(&data_cw, &bit_len, 0, @intCast(term));
    while (bit_len % 8 != 0) appendBits(&data_cw, &bit_len, 0, 1);
    var pad_idx: usize = bit_len / 8;
    var pad_toggle = false;
    while (pad_idx < spec.data_codewords) : (pad_idx += 1) {
        data_cw[pad_idx] = if (pad_toggle) 0x11 else 0xec;
        pad_toggle = !pad_toggle;
    }

    // 2. Reed-Solomon error correction and block interleaving.
    var codewords: [292]u8 = undefined;
    var cw_len: usize = 0;
    const block_data_len = spec.data_codewords / spec.num_blocks;
    var ec_blocks: [2][30]u8 = undefined;
    for (0..spec.num_blocks) |b| {
        const start = b * block_data_len;
        computeReedSolomon(
            data_cw[start .. start + block_data_len],
            spec.ec_per_block,
            ec_blocks[b][0..spec.ec_per_block],
        );
    }
    for (0..block_data_len) |i| {
        for (0..spec.num_blocks) |b| {
            codewords[cw_len] = data_cw[b * block_data_len + i];
            cw_len += 1;
        }
    }
    for (0..spec.ec_per_block) |i| {
        for (0..spec.num_blocks) |b| {
            codewords[cw_len] = ec_blocks[b][i];
            cw_len += 1;
        }
    }

    // 3. Place function patterns (finders, separators, alignment, timing, dark module, version/format).
    var base: Matrix = .{ .size = size };
    drawFinder(&base, 0, 0);
    drawFinder(&base, size - 7, 0);
    drawFinder(&base, 0, size - 7);

    const align_coords = spec.alignment;
    for (align_coords, 0..) |cy, iy| {
        for (align_coords, 0..) |cx, ix| {
            const is_finder_corner = (ix == 0 and iy == 0) or
                (ix == 0 and iy + 1 == align_coords.len) or
                (ix + 1 == align_coords.len and iy == 0);
            if (!is_finder_corner) drawAlignment(&base, cx, cy);
        }
    }

    for (8..size - 8) |i| {
        const dark = (i % 2 == 0);
        if (!base.is_function[6][i]) base.setFunction(i, 6, dark);
        if (!base.is_function[i][6]) base.setFunction(6, i, dark);
    }

    // Dark module and reserved format information areas.
    base.setFunction(8, 4 * @as(usize, version) + 9, true);
    for (0..9) |i| {
        if (!base.is_function[8][i]) base.setFunction(i, 8, false);
        if (!base.is_function[i][8]) base.setFunction(8, i, false);
    }
    for (0..8) |i| {
        base.setFunction(size - 1 - i, 8, false);
    }
    for (0..7) |i| {
        base.setFunction(8, size - 1 - i, false);
    }

    // Version information (Versions 7–9).
    if (version >= 7) {
        var v_bits = spec.version_info;
        for (0..6) |i| {
            for (0..3) |j| {
                const bit = (v_bits & 1) != 0;
                v_bits >>= 1;
                base.setFunction(size - 11 + j, i, bit);
                base.setFunction(i, size - 11 + j, bit);
            }
        }
    }

    // 4. Place data and EC bits in zigzag order.
    placeDataBits(&base, codewords[0..cw_len]);

    // 5. Choose the mask (0..7) with the lowest penalty score.
    var best_matrix = base;
    var best_score: u32 = std.math.maxInt(u32);
    for (0..8) |mask_idx| {
        var candidate = base;
        const mask: u3 = @intCast(mask_idx);
        applyMask(&candidate, mask);
        drawFormatBits(&candidate, mask);
        const score = penaltyScore(&candidate);
        if (score < best_score) {
            best_score = score;
            best_matrix = candidate;
        }
    }
    return best_matrix;
}

fn appendBits(buf: []u8, bit_len: *usize, val: u16, count: u4) void {
    var i: u4 = count;
    while (i > 0) {
        i -= 1;
        const bit: u8 = @intCast((val >> i) & 1);
        const byte_idx = bit_len.* / 8;
        const bit_idx: u3 = @intCast(7 - (bit_len.* % 8));
        buf[byte_idx] |= bit << bit_idx;
        bit_len.* += 1;
    }
}

fn gfMul(a: u8, b: u8) u8 {
    var p: u8 = 0;
    var x = a;
    var y = b;
    for (0..8) |_| {
        if ((y & 1) != 0) p ^= x;
        const hi = (x & 0x80) != 0;
        x <<= 1;
        if (hi) x ^= 0x1d;
        y >>= 1;
    }
    return p;
}

fn computeReedSolomon(data: []const u8, degree: u8, out_ec: []u8) void {
    var gen: [30]u8 = @splat(0);
    gen[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            gen[j] = gfMul(gen[j], root);
            if (j + 1 < degree) gen[j] ^= gen[j + 1];
        }
        root = gfMul(root, 2);
    }

    @memset(out_ec, 0);
    for (data) |b| {
        const factor = b ^ out_ec[0];
        for (0..degree - 1) |j| {
            out_ec[j] = out_ec[j + 1] ^ gfMul(gen[j], factor);
        }
        out_ec[degree - 1] = gfMul(gen[degree - 1], factor);
    }
}

fn drawFinder(m: *Matrix, ox: usize, oy: usize) void {
    const s = m.size;
    var dy: isize = -1;
    while (dy <= 7) : (dy += 1) {
        var dx: isize = -1;
        while (dx <= 7) : (dx += 1) {
            const x = @as(isize, @intCast(ox)) + dx;
            const y = @as(isize, @intCast(oy)) + dy;
            if (x < 0 or y < 0 or x >= s or y >= s) continue;
            const in_outer = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6;
            const on_border = dx == 0 or dx == 6 or dy == 0 or dy == 6;
            const in_inner = dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4;
            const dark = in_outer and (on_border or in_inner);
            m.setFunction(@intCast(x), @intCast(y), dark);
        }
    }
}

fn drawAlignment(m: *Matrix, cx: usize, cy: usize) void {
    var dy: isize = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: isize = -2;
        while (dx <= 2) : (dx += 1) {
            const dist = @max(@abs(dx), @abs(dy));
            const x: usize = @intCast(@as(isize, @intCast(cx)) + dx);
            const y: usize = @intCast(@as(isize, @intCast(cy)) + dy);
            m.setFunction(x, y, dist != 1);
        }
    }
}

fn placeDataBits(m: *Matrix, codewords: []const u8) void {
    const s: usize = m.size;
    var bit_idx: usize = 0;
    const total_bits = codewords.len * 8;
    var right: isize = @as(isize, @intCast(s)) - 1;
    var upward = true;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;
        for (0..s) |step| {
            const y: usize = if (upward) s - 1 - step else step;
            for (0..2) |col_off| {
                const x: usize = @intCast(right - @as(isize, @intCast(col_off)));
                if (m.is_function[y][x]) continue;
                var dark = false;
                if (bit_idx < total_bits) {
                    const cw = codewords[bit_idx / 8];
                    const shift: u3 = @intCast(7 - (bit_idx % 8));
                    dark = ((cw >> shift) & 1) != 0;
                    bit_idx += 1;
                }
                m.modules[y][x] = dark;
            }
        }
        upward = !upward;
    }
}

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (y + x) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (y + x) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (y * x) % 2 + (y * x) % 3 == 0,
        6 => ((y * x) % 2 + (y * x) % 3) % 2 == 0,
        7 => ((y + x) % 2 + (y * x) % 3) % 2 == 0,
    };
}

fn applyMask(m: *Matrix, mask: u3) void {
    const s: usize = m.size;
    for (0..s) |y| {
        for (0..s) |x| {
            if (!m.is_function[y][x] and maskBit(mask, x, y)) {
                m.modules[y][x] = !m.modules[y][x];
            }
        }
    }
}

fn formatBits(mask: u3) u15 {
    // ECC Level L indicator is 01.
    const data: u15 = (@as(u15, 0b01) << 3) | @as(u15, mask);
    var rem: u15 = data << 10;
    var i: u4 = 14;
    while (i >= 10) : (i -= 1) {
        if (((rem >> i) & 1) != 0) {
            rem ^= (@as(u15, 0x537) << (i - 10));
        }
        if (i == 10) break;
    }
    return ((data << 10) | rem) ^ 0x5412;
}

fn drawFormatBits(m: *Matrix, mask: u3) void {
    const bits = formatBits(mask);
    const s: usize = m.size;
    for (0..6) |i| m.setFunction(8, i, ((bits >> @intCast(i)) & 1) != 0);
    m.setFunction(8, 7, ((bits >> 6) & 1) != 0);
    m.setFunction(8, 8, ((bits >> 7) & 1) != 0);
    m.setFunction(7, 8, ((bits >> 8) & 1) != 0);
    for (9..15) |i| m.setFunction(14 - i, 8, ((bits >> @intCast(i)) & 1) != 0);

    for (0..8) |i| m.setFunction(s - 1 - i, 8, ((bits >> @intCast(i)) & 1) != 0);
    for (8..15) |i| m.setFunction(8, s - 15 + i, ((bits >> @intCast(i)) & 1) != 0);
}

fn penaltyScore(m: *const Matrix) u32 {
    const s: usize = m.size;
    var score: u32 = 0;

    // Rule 1: runs of 5+ same-colored modules in rows and columns.
    for (0..s) |y| {
        var run_color = m.modules[y][0];
        var run_len: u32 = 1;
        for (1..s) |x| {
            if (m.modules[y][x] == run_color) {
                run_len += 1;
                if (run_len == 5) score += 3 else if (run_len > 5) score += 1;
            } else {
                run_color = m.modules[y][x];
                run_len = 1;
            }
        }
    }
    for (0..s) |x| {
        var run_color = m.modules[0][x];
        var run_len: u32 = 1;
        for (1..s) |y| {
            if (m.modules[y][x] == run_color) {
                run_len += 1;
                if (run_len == 5) score += 3 else if (run_len > 5) score += 1;
            } else {
                run_color = m.modules[y][x];
                run_len = 1;
            }
        }
    }

    // Rule 2: 2x2 blocks of same-colored modules.
    for (0..s - 1) |y| {
        for (0..s - 1) |x| {
            const c = m.modules[y][x];
            if (m.modules[y][x + 1] == c and m.modules[y + 1][x] == c and m.modules[y + 1][x + 1] == c) {
                score += 3;
            }
        }
    }

    // Rule 3: 1:1:3:1:1 finder-like patterns in rows and columns.
    for (0..s) |y| {
        for (0..s - 6) |x| {
            if (m.modules[y][x] and !m.modules[y][x + 1] and m.modules[y][x + 2] and
                m.modules[y][x + 3] and m.modules[y][x + 4] and !m.modules[y][x + 5] and m.modules[y][x + 6])
            {
                const quiet_left = x >= 4 and !m.modules[y][x - 1] and !m.modules[y][x - 2] and !m.modules[y][x - 3] and !m.modules[y][x - 4];
                const quiet_right = x + 10 < s and !m.modules[y][x + 7] and !m.modules[y][x + 8] and !m.modules[y][x + 9] and !m.modules[y][x + 10];
                if (quiet_left or quiet_right) score += 40;
            }
        }
    }
    for (0..s) |x| {
        for (0..s - 6) |y| {
            if (m.modules[y][x] and !m.modules[y + 1][x] and m.modules[y + 2][x] and
                m.modules[y + 3][x] and m.modules[y + 4][x] and !m.modules[y + 5][x] and m.modules[y + 6][x])
            {
                const quiet_top = y >= 4 and !m.modules[y - 1][x] and !m.modules[y - 2][x] and !m.modules[y - 3][x] and !m.modules[y - 4][x];
                const quiet_bottom = y + 10 < s and !m.modules[y + 7][x] and !m.modules[y + 8][x] and !m.modules[y + 9][x] and !m.modules[y + 10][x];
                if (quiet_top or quiet_bottom) score += 40;
            }
        }
    }

    // Rule 4: balance of dark and light modules.
    var dark_count: u32 = 0;
    for (0..s) |y| {
        for (0..s) |x| {
            if (m.modules[y][x]) dark_count += 1;
        }
    }
    const total: u32 = @intCast(s * s);
    const k = (@abs(@as(i32, @intCast(dark_count * 20)) - @as(i32, @intCast(total * 10))) + total - 1) / total;
    score += k * 10;
    return score;
}

const testing = std.testing;

test "QR Code encoding produces valid finder, timing, and Reed-Solomon structure" {
    const m = encode("WIFI:T:WPA;S:MyNetwork;P:secretpass;;").?;
    // 37-byte payload fits in Version 3 (29x29 modules).
    try testing.expectEqual(@as(u8, 29), m.size);
    // Top-left finder corners and center are dark, separator is light.
    try testing.expect(m.get(0, 0));
    try testing.expect(m.get(6, 0));
    try testing.expect(m.get(3, 3));
    try testing.expect(!m.get(1, 1));
    try testing.expect(!m.get(7, 0));
    try testing.expect(!m.get(0, 7));
    // Timing pattern alternates along row 6 and col 6.
    try testing.expect(m.get(8, 6));
    try testing.expect(!m.get(9, 6));
    try testing.expect(m.get(10, 6));
}
