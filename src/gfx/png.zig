//! Reading and writing PNG images: 8-bit RGB or RGBA when writing (each row
//! filtered by its difference from the pixel before, compressed with deflate
//! at its fastest), and every colour type and depth, interlaced (Adam7) or
//! not, when reading (decoded to 0xAARRGGBB, straight alpha).

const std = @import("std");

pub const Error = error{ Unsupported, Malformed, TooBig, OutOfMemory };

pub const Decoded = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

/// The most pixels decoded.
pub const max_pixels = 32 * 1024 * 1024;

/// The most pixels an image may have when only part of it is decoded (a
/// `Region` of at most `max_pixels`).
pub const max_source_pixels = 16 * max_pixels;

/// A part of an image, in pixels: `w` across and `h` down from (`x`, `y`).
pub const Region = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    /// `r` within an image `width` by `height` (all of it, if null);
    /// none of it there is malformed, and more than `max_pixels` too big.
    pub fn within(r: ?Region, width: u32, height: u32) Error!Region {
        const want = r orelse Region{ .x = 0, .y = 0, .w = width, .h = height };
        if (want.x >= width or want.y >= height or want.w == 0 or want.h == 0) return error.Malformed;
        const out: Region = .{ .x = want.x, .y = want.y, .w = @min(want.w, width - want.x), .h = @min(want.h, height - want.y) };
        if (@as(u64, out.w) * out.h > max_pixels) return error.TooBig;
        if (r == null and @as(u64, width) * height > max_pixels) return error.TooBig;
        if (@as(u64, width) * height > max_source_pixels) return error.TooBig;
        return out;
    }

    pub fn x1(r: Region) u32 {
        return r.x + r.w;
    }

    pub fn y1(r: Region) u32 {
        return r.y + r.h;
    }
};

/// The part `r` of `img` (which must be within it), in new pixels.
pub fn crop(gpa: std.mem.Allocator, img: Decoded, r: Region) Error!Decoded {
    const out = try gpa.alloc(u32, @as(usize, r.w) * r.h);
    for (0..r.h) |y| @memcpy(out[y * r.w ..][0..r.w], img.pixels[(r.y + y) * img.width + r.x ..][0..r.w]);
    return .{ .pixels = out, .width = r.w, .height = r.h };
}

/// The PNG of `pixels` (0x__RRGGBB, alpha ignored), `width` by `height`.
pub fn encode(gpa: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    return encodeChannels(gpa, pixels, width, height, 3);
}

/// The RGBA PNG of `pixels` (0xAARRGGBB, straight alpha), `width` by `height`.
pub fn encodeRgba(gpa: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    return encodeChannels(gpa, pixels, width, height, 4);
}

fn encodeChannels(gpa: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, comptime channels: usize) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, if (channels == 4) 6 else 2, 0, 0, 0 }; // 8 bits, RGB/RGBA, deflate, filters, not interlaced
    try chunk(gpa, &out, "IHDR", &ihdr);

    // The rows, filtered, then compressed.
    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer z.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .fastest);
    const row = try gpa.alloc(u8, 1 + @as(usize, width) * channels);
    defer gpa.free(row);
    for (0..height) |y| {
        row[0] = 1; // Sub: each byte less the one a pixel before
        var prev: [channels]u8 = @splat(0);
        for (pixels[y * width ..][0..width], 0..) |p, x| {
            const px: [channels]u8 = if (channels == 4)
                .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) }
            else
                .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) };
            for (0..channels) |k| row[1 + x * channels + k] = px[k] -% prev[k];
            prev = px;
        }
        try c.writer.writeAll(row);
    }
    try c.finish();
    try chunk(gpa, &out, "IDAT", z.written());
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(body.len), .big);
    try out.appendSlice(gpa, &b);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    std.mem.writeInt(u32, &b, crc.final(), .big);
    try out.appendSlice(gpa, &b);
}

/// Decodes a PNG image to 0xAARRGGBB pixels (straight alpha).
pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    return decodeRegion(gpa, data, null);
}

/// Decodes part of a PNG image (all of it if `region` is null): its rows
/// are inflated one at a time, keeping only what is in the region, and
/// (if it is not interlaced) no further than its last.
pub fn decodeRegion(gpa: std.mem.Allocator, data: []const u8, region: ?Region) Error!Decoded {
    if (!std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return error.Malformed;
    var at: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var palette: [256]u32 = @splat(0xff000000);
    var palette_len: usize = 0;
    // A colour that is transparent (grey or RGB images), 16-bit samples.
    var key: ?[3]u16 = null;
    var interlaced = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (at + 12 <= data.len) {
        const len = be32(data, at);
        const kind = data[at + 4 ..][0..4];
        if (len > data.len - at - 12) return error.Malformed;
        const body = data[at + 8 ..][0..len];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Malformed;
            width = be32(body, 0);
            height = be32(body, 4);
            depth = body[8];
            color = body[9];
            if (body[10] != 0 or body[11] != 0) return error.Unsupported;
            if (body[12] > 1) return error.Unsupported;
            interlaced = body[12] == 1;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_len = @min(len / 3, 256);
            for (0..palette_len) |i| palette[i] = argb(body[i * 3], body[i * 3 + 1], body[i * 3 + 2], 255);
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (color) {
                3 => for (body[0..@min(len, 256)], 0..) |a, i| {
                    palette[i] = palette[i] & 0x00ffffff | @as(u32, a) << 24;
                },
                0 => if (len >= 2) {
                    const g = std.mem.readInt(u16, body[0..2], .big);
                    key = .{ g, g, g };
                },
                2 => if (len >= 6) {
                    key = .{ std.mem.readInt(u16, body[0..2], .big), std.mem.readInt(u16, body[2..4], .big), std.mem.readInt(u16, body[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    const channels: u32 = switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    const depth_ok = switch (color) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        else => depth == 8 or depth == 16,
    };
    if (!depth_ok) return error.Unsupported;
    if (width == 0 or height == 0) return error.Malformed;
    const r = try Region.within(region, width, height);
    const pixels = try gpa.alloc(u32, @as(usize, r.w) * r.h);
    errdefer gpa.free(pixels);
    const bits = channels * depth;
    // Bytes to the corresponding byte of the pixel before (at least one).
    const bpp = @max(bits / 8, 1);
    // The passes: all the pixels, or Adam7's seven, each starting at
    // (x, y) and taking every dx-th across and dy-th down.
    const all = [_][4]u8{.{ 0, 0, 1, 1 }};
    const adam7 = [_][4]u8{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
    const passes: []const [4]u8 = if (interlaced) &adam7 else &all;
    // A row and the one before it, as wide as the widest pass's.
    const widest = (@as(usize, width) * bits + 7) / 8 + 1;
    const lines = try gpa.alloc(u8, widest * 2);
    defer gpa.free(lines);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var input = std.Io.Reader.fixed(idat.items);
    var z = std.compress.flate.Decompress.init(&input, .zlib, window);

    for (passes) |pass| {
        const pw, const ph = passSize(width, height, pass);
        if (pw == 0 or ph == 0) continue;
        const stride = (pw * bits + 7) / 8;
        var prev: []u8 = &.{};
        for (0..ph) |py| {
            const y = pass[1] + py * pass[3];
            // Not interlaced, nothing below the region is needed.
            if (!interlaced and y >= r.y1()) break;
            const line = lines[(py % 2) * widest ..][0 .. stride + 1];
            z.reader.readSliceAll(line) catch return error.Malformed;
            const row = line[1..];
            try unfilter(line[0], row, prev, bpp);
            prev = row;
            if (y < r.y or y >= r.y1()) continue;
            // The pass's pixels in the region's columns.
            var px: usize = if (r.x > pass[0]) (r.x - pass[0] + pass[2] - 1) / pass[2] else 0;
            while (px < pw) : (px += 1) {
                const x = pass[0] + px * pass[2];
                if (x >= r.x1()) break;
                pixels[(y - r.y) * r.w + (x - r.x)] = pixel(row, px, color, depth, &palette, key);
            }
        }
    }
    return .{ .pixels = pixels, .width = r.w, .height = r.h };
}

/// How many pixels across and down an Adam7 pass (or all the pixels) has.
fn passSize(width: u32, height: u32, pass: [4]u8) struct { usize, usize } {
    const w = if (width > pass[0]) (width - pass[0] + pass[2] - 1) / pass[2] else 0;
    const h = if (height > pass[1]) (height - pass[1] + pass[3] - 1) / pass[3] else 0;
    return .{ w, h };
}

/// Pixel `x` of an unfiltered row.
fn pixel(row: []const u8, x: usize, color: u8, depth: u8, palette: *const [256]u32, key: ?[3]u16) u32 {
    return switch (color) {
        3 => palette[sample(row, x, depth)],
        0 => blk: {
            const v = sample(row, x, depth);
            const g = scale(v, depth);
            const opaque_ = if (key) |k| v != k[0] else true;
            break :blk argb(g, g, g, if (opaque_) 255 else 0);
        },
        2 => blk: {
            const r = sample(row, x * 3, depth);
            const g = sample(row, x * 3 + 1, depth);
            const b = sample(row, x * 3 + 2, depth);
            const opaque_ = if (key) |k| !(r == k[0] and g == k[1] and b == k[2]) else true;
            break :blk argb(scale(r, depth), scale(g, depth), scale(b, depth), if (opaque_) 255 else 0);
        },
        4 => blk: {
            const g = scale(sample(row, x * 2, depth), depth);
            break :blk argb(g, g, g, scale(sample(row, x * 2 + 1, depth), depth));
        },
        else => argb(scale(sample(row, x * 4, depth), depth), scale(sample(row, x * 4 + 1, depth), depth), scale(sample(row, x * 4 + 2, depth), depth), scale(sample(row, x * 4 + 3, depth), depth)),
    };
}

fn be32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

fn argb(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, g) << 8 | b;
}

/// Sample `i` of a row, `depth` bits each.
fn sample(row: []const u8, i: usize, depth: u8) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        8 => row[i],
        else => blk: {
            const bit = i * depth;
            const shift: u3 = @intCast(8 - depth - bit % 8);
            break :blk (row[bit / 8] >> shift) & ((@as(u8, 1) << @intCast(depth)) - 1);
        },
    };
}

/// A sample as 8 bits.
fn scale(v: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

fn unfilter(filter: u8, row: []u8, prev: []const u8, bpp: usize) Error!void {
    for (row, 0..) |*byte, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b: u8 = if (prev.len > 0) prev[i] else 0;
        const c: u8 = if (i >= bpp and prev.len > 0) prev[i - bpp] else 0;
        byte.* +%= switch (filter) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            4 => paeth(a, b, c),
            else => return error.Malformed,
        };
    }
}

pub fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

const testing = std.testing;

test "a PNG that decodes to the pixels" {
    const gpa = testing.allocator;
    const pixels = [_]u32{ 0xffff0000, 0xff00ff00, 0x000000ff, 0xff102030, 0xff102031, 0xffffffff };
    const png = try encode(gpa, &pixels, 3, 2);
    defer gpa.free(png);
    try testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x03\x00\x00\x00\x02\x08\x02"));
    const decoded = try decode(gpa, png);
    defer gpa.free(decoded.pixels);
    try testing.expectEqual(@as(u32, 3), decoded.width);
    try testing.expectEqual(@as(u32, 2), decoded.height);
    for (pixels, decoded.pixels) |want, got| try testing.expectEqual(want | 0xff000000, got);
    try testing.expect(std.mem.endsWith(u8, png, "IEND\xae\x42\x60\x82"));

    const rgba_png = try encodeRgba(gpa, &pixels, 3, 2);
    defer gpa.free(rgba_png);
    const decoded_rgba = try decode(gpa, rgba_png);
    defer gpa.free(decoded_rgba.pixels);
    try testing.expectEqualSlices(u32, &pixels, decoded_rgba.pixels);
}

test "interlaced (Adam7) PNGs decode, passes empty or not" {
    const gpa = testing.allocator;
    {
        const img = try decode(gpa, @embedFile("testdata/adam7_rgba.png"));
        defer gpa.free(img.pixels);
        try testing.expectEqual(@as(u32, 13), img.width);
        for (0..9) |y| for (0..13) |x| {
            const r: u32 = @intCast(x * 20 % 256);
            const g: u32 = @intCast(y * 25 % 256);
            const b: u32 = @intCast(x * y * 7 % 256);
            const a: u32 = @intCast(255 - x * 10 % 256);
            try testing.expectEqual(a << 24 | r << 16 | g << 8 | b, img.pixels[y * 13 + x]);
        };
    }
    {
        const img = try decode(gpa, @embedFile("testdata/adam7_grey16.png"));
        defer gpa.free(img.pixels);
        for (0..3) |y| for (0..3) |x| {
            const v: u32 = @intCast(((x * 1000 + y * 3000) % 65536) >> 8);
            try testing.expectEqual(0xff000000 | v << 16 | v << 8 | v, img.pixels[y * 3 + x]);
        };
    }
    {
        const img = try decode(gpa, @embedFile("testdata/adam7_1x1.png"));
        defer gpa.free(img.pixels);
        try testing.expectEqualSlices(u32, &.{0xff0a141e}, img.pixels);
    }
    {
        const img = try decode(gpa, @embedFile("testdata/adam7_palette2.png"));
        defer gpa.free(img.pixels);
        const palette = [4]u32{ 0xffff0000, 0x8000ff00, 0xff0000ff, 0xffffffff };
        for (0..6) |y| for (0..11) |x| try testing.expectEqual(palette[(x + y) % 4], img.pixels[y * 11 + x]);
    }
}

/// `region` of `full` (decoded whole): what decoding just the region gives.
pub fn expectRegion(full: Decoded, part: Decoded, region: Region) !void {
    try testing.expectEqual(region.w, part.width);
    try testing.expectEqual(region.h, part.height);
    for (0..region.h) |y| try testing.expectEqualSlices(u32, full.pixels[(region.y + y) * full.width + region.x ..][0..region.w], part.pixels[y * region.w ..][0..region.w]);
}

test "parts of PNGs decode to those parts, interlaced or not" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        @embedFile("testdata/adam7_rgba.png"),
        @embedFile("testdata/adam7_palette2.png"),
    }) |data| {
        const full = try decode(gpa, data);
        defer gpa.free(full.pixels);
        for ([_]Region{ .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 3, .y = 2, .w = 5, .h = 3 }, .{ .x = 4, .y = 1, .w = 100, .h = 100 } }) |reg| {
            const want = try Region.within(reg, full.width, full.height);
            const part = try decodeRegion(gpa, data, reg);
            defer gpa.free(part.pixels);
            try expectRegion(full, part, want);
        }
        try testing.expectError(error.Malformed, decodeRegion(gpa, data, .{ .x = 50, .y = 0, .w = 2, .h = 2 }));
    }
    // Not interlaced.
    var px: [40 * 30]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @intCast(i * 2654435761 % 0xffffff));
    const png = try encode(gpa, &px, 40, 30);
    defer gpa.free(png);
    const full = try decode(gpa, png);
    defer gpa.free(full.pixels);
    const reg: Region = .{ .x = 7, .y = 11, .w = 20, .h = 9 };
    const part = try decodeRegion(gpa, png, reg);
    defer gpa.free(part.pixels);
    try expectRegion(full, part, reg);
}
