//! Reading and writing PNG images: 8-bit RGB or RGBA when writing (each row
//! filtered by its difference from the pixel before, compressed with deflate
//! at its fastest), and every non-interlaced colour type and depth when
//! reading (decoded to 0xAARRGGBB, straight alpha).

const std = @import("std");

pub const Error = error{ Unsupported, Malformed, TooBig, OutOfMemory };

pub const Decoded = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

/// The most pixels decoded.
pub const max_pixels = 32 * 1024 * 1024;

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
            if (body[12] != 0) return error.Unsupported; // interlaced
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
    if (@as(u64, width) * height > max_pixels) return error.TooBig;
    const pixels = try gpa.alloc(u32, @as(usize, width) * height);
    errdefer gpa.free(pixels);
    const bits = channels * depth;
    const stride = (@as(usize, width) * bits + 7) / 8;
    // Bytes to the corresponding byte of the pixel before (at least one).
    const bpp = @max(bits / 8, 1);
    const raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var input = std.Io.Reader.fixed(idat.items);
    var z = std.compress.flate.Decompress.init(&input, .zlib, window);
    z.reader.readSliceAll(raw) catch return error.Malformed;

    var prev: []u8 = &.{};
    for (0..height) |y| {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        const row = line[1..];
        try unfilter(line[0], row, prev, bpp);
        prev = row;
        for (0..width) |x| {
            pixels[y * width + x] = switch (color) {
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
    }
    return .{ .pixels = pixels, .width = width, .height = height };
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
