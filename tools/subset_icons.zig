//! Makes Facet's icon font: the Material Icons font cut down to the icons
//! Facet includes (`Icon`, in src/icons/names.zig), leaving out unused
//! glyphs. The full font has over 2000 icons (350 KB); a few dozen are a
//! few kilobytes.
//!
//!     subset_icons <font.ttf> <font.codepoints> <out.ttf> <out.zig>
//!
//! The codepoints file names each icon's codepoint ("folder e2c7"); an
//! icon it does not name is an error. out.zig lists the codepoints, in the
//! order of `Icon`. out.ttf has the icons' glyphs (and those they are made
//! of), with the tables Facet's font reader needs: TrueType outlines,
//! metrics and a character map. The ligatures that let the full font
//! draw "folder" as the icon are left out: icons are drawn by codepoint.

const std = @import("std");
const font = @import("font");
const Icon = @import("icon_names").Icon;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: subset_icons <font.ttf> <font.codepoints> <out.ttf> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, args[1], arena, .limited(16 << 20));
    const names = try cwd.readFileAlloc(init.io, args[2], arena, .limited(1 << 20));

    const field_names = @typeInfo(Icon).@"enum".field_names;
    var codepoints: [field_names.len]u21 = undefined;
    inline for (field_names, &codepoints) |field_name, *cp| {
        cp.* = lookup(names, field_name) orelse {
            std.debug.print("subset_icons: no icon called \"{s}\" in {s}\n", .{ field_name, args[2] });
            std.process.exit(1);
        };
    }

    const out = try subset(arena, data, &codepoints);
    const ttf = try cwd.createFile(init.io, args[3], .{});
    defer ttf.close(init.io);
    try ttf.writeStreamingAll(init.io, out);

    var zig: std.ArrayList(u8) = .empty;
    try zig.appendSlice(arena, "//! Made by tools/subset_icons.zig: each icon's codepoint, in the order of `Icon`.\n\npub const codepoints = [_]u21{\n");
    for (codepoints) |cp| try zig.print(arena, "    0x{x},\n", .{cp});
    try zig.appendSlice(arena, "};\n");
    const z = try cwd.createFile(init.io, args[4], .{});
    defer z.close(init.io);
    try z.writeStreamingAll(init.io, zig.items);
}

/// The codepoint the codepoints file gives `name`.
fn lookup(names: []const u8, name: []const u8) ?u21 {
    var lines = std.mem.tokenizeScalar(u8, names, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, f.next() orelse continue, name)) continue;
        return std.fmt.parseInt(u21, f.next() orelse return null, 16) catch null;
    }
    return null;
}

fn be16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

fn be32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

fn put16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .big);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .big);
}

fn findTable(data: []const u8, name: *const [4]u8) ![]const u8 {
    const n = be16(data, 4);
    for (0..n) |i| {
        const rec = 12 + i * 16;
        if (!std.mem.eql(u8, data[rec..][0..4], name)) continue;
        const off = be32(data, rec + 8);
        const len = be32(data, rec + 12);
        if (off + len > data.len) return error.Malformed;
        return data[off..][0..len];
    }
    return error.Malformed;
}

/// A glyph's outline data in `glyf`.
fn glyphData(loca: []const u8, glyf: []const u8, long: bool, g: u16) ![]const u8 {
    const start: usize = if (long) be32(loca, @as(usize, g) * 4) else @as(usize, be16(loca, @as(usize, g) * 2)) * 2;
    const end: usize = if (long) be32(loca, @as(usize, g) * 4 + 4) else @as(usize, be16(loca, @as(usize, g) * 2 + 2)) * 2;
    if (start > end or end > glyf.len) return error.Malformed;
    return glyf[start..end];
}

const ARG_1_AND_2_ARE_WORDS = 0x0001;
const WE_HAVE_A_SCALE = 0x0008;
const MORE_COMPONENTS = 0x0020;
const WE_HAVE_AN_X_AND_Y_SCALE = 0x0040;
const WE_HAVE_A_TWO_BY_TWO = 0x0080;

/// Where each component's glyph index is in a composite glyph.
fn components(g: []const u8, out: *std.ArrayList(usize), gpa: std.mem.Allocator) !void {
    if (g.len < 10 or @as(i16, @bitCast(be16(g, 0))) >= 0) return;
    var at: usize = 10;
    while (at + 4 <= g.len) {
        const flags = be16(g, at);
        try out.append(gpa, at + 2);
        at += 4 + @as(usize, if (flags & ARG_1_AND_2_ARE_WORDS != 0) 4 else 2);
        if (flags & WE_HAVE_A_SCALE != 0) at += 2 else if (flags & WE_HAVE_AN_X_AND_Y_SCALE != 0) at += 4 else if (flags & WE_HAVE_A_TWO_BY_TWO != 0) at += 8;
        if (flags & MORE_COMPONENTS == 0) break;
    }
}

/// The font with only the glyphs for `codepoints` (and .notdef, and the
/// glyphs they are made of).
pub fn subset(gpa: std.mem.Allocator, data: []const u8, codepoints: []const u21) ![]u8 {
    const f = try font.Font.init(data);
    const head = try findTable(data, "head");
    const hhea = try findTable(data, "hhea");
    const maxp = try findTable(data, "maxp");
    const loca = try findTable(data, "loca");
    const glyf = try findTable(data, "glyf");
    const long = be16(head, 50) == 1;

    // The glyphs kept, old index to new: .notdef first, then the icons'
    // (and their components'), in the order found.
    var old: std.ArrayList(u16) = .empty;
    var new_of: std.AutoHashMapUnmanaged(u16, u16) = .empty;
    try old.append(gpa, 0);
    try new_of.put(gpa, 0, 0);
    var i: usize = 0;
    var cmap_glyphs: std.ArrayList(u16) = .empty;
    for (codepoints) |cp| {
        const g = f.glyphIndex(cp);
        if (g == 0) return error.MissingGlyph;
        if (!new_of.contains(g)) {
            try new_of.put(gpa, g, @intCast(old.items.len));
            try old.append(gpa, g);
        }
        try cmap_glyphs.append(gpa, new_of.get(g).?);
    }
    while (i < old.items.len) : (i += 1) {
        var comps: std.ArrayList(usize) = .empty;
        const gd = try glyphData(loca, glyf, long, old.items[i]);
        try components(gd, &comps, gpa);
        for (comps.items) |at| {
            const c = be16(gd, at);
            if (!new_of.contains(c)) {
                try new_of.put(gpa, c, @intCast(old.items.len));
                try old.append(gpa, c);
            }
        }
    }
    const n: u16 = @intCast(old.items.len);

    // glyf and loca (long offsets), with components renumbered.
    var new_glyf: std.ArrayList(u8) = .empty;
    var new_loca: std.ArrayList(u8) = .empty;
    for (old.items) |g| {
        try appendBe32(&new_loca, gpa, @intCast(new_glyf.items.len));
        const start = new_glyf.items.len;
        try new_glyf.appendSlice(gpa, try glyphData(loca, glyf, long, g));
        var comps: std.ArrayList(usize) = .empty;
        try components(new_glyf.items[start..], &comps, gpa);
        for (comps.items) |at| put16(new_glyf.items[start..], at, new_of.get(be16(new_glyf.items[start..], at)).?);
        while (new_glyf.items.len % 4 != 0) try new_glyf.append(gpa, 0);
    }
    try appendBe32(&new_loca, gpa, @intCast(new_glyf.items.len));

    // A metric each.
    var hmtx: std.ArrayList(u8) = .empty;
    for (old.items) |g| {
        try appendBe16(&hmtx, gpa, f.advance(g));
        try appendBe16(&hmtx, gpa, @bitCast(f.leftSideBearing(g)));
    }

    const new_head = try gpa.dupe(u8, head);
    put32(new_head, 8, 0); // checkSumAdjustment, set last
    put16(new_head, 50, 1); // long loca offsets
    const new_hhea = try gpa.dupe(u8, hhea);
    put16(new_hhea, 34, n); // numberOfHMetrics
    const new_maxp = try gpa.dupe(u8, maxp);
    put16(new_maxp, 4, n); // numGlyphs

    // cmap: a format 12 subtable (Windows, full Unicode), a group per
    // codepoint.
    const Pair = struct { cp: u21, glyph: u16 };
    const pairs = try gpa.alloc(Pair, codepoints.len);
    for (pairs, codepoints, cmap_glyphs.items) |*p, cp, g| p.* = .{ .cp = cp, .glyph = g };
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.cp < b.cp;
        }
    }.lt);
    var cmap: std.ArrayList(u8) = .empty;
    try appendBe16(&cmap, gpa, 0); // version
    try appendBe16(&cmap, gpa, 1); // one subtable
    try appendBe16(&cmap, gpa, 3); // Windows
    try appendBe16(&cmap, gpa, 10); // full Unicode
    try appendBe32(&cmap, gpa, 12);
    try appendBe16(&cmap, gpa, 12); // format
    try appendBe16(&cmap, gpa, 0);
    try appendBe32(&cmap, gpa, @intCast(16 + 12 * pairs.len));
    try appendBe32(&cmap, gpa, 0); // language
    try appendBe32(&cmap, gpa, @intCast(pairs.len));
    for (pairs) |p| {
        try appendBe32(&cmap, gpa, p.cp);
        try appendBe32(&cmap, gpa, p.cp);
        try appendBe32(&cmap, gpa, p.glyph);
    }

    // post, version 3: no glyph names.
    const post = try gpa.dupe(u8, (try findTable(data, "post"))[0..32]);
    put32(post, 0, 0x00030000);

    const Table = struct { tag: *const [4]u8, data: []const u8 };
    // In tag order, as the table directory must be.
    const tables = [_]Table{
        .{ .tag = "cmap", .data = cmap.items },
        .{ .tag = "glyf", .data = new_glyf.items },
        .{ .tag = "head", .data = new_head },
        .{ .tag = "hhea", .data = new_hhea },
        .{ .tag = "hmtx", .data = hmtx.items },
        .{ .tag = "loca", .data = new_loca.items },
        .{ .tag = "maxp", .data = new_maxp },
        .{ .tag = "post", .data = post },
    };
    var out: std.ArrayList(u8) = .empty;
    const num: u16 = tables.len;
    var power: u16 = 1;
    var log2: u16 = 0;
    while (power * 2 <= num) : (log2 += 1) power *= 2;
    try appendBe32(&out, gpa, 0x00010000);
    try appendBe16(&out, gpa, num);
    try appendBe16(&out, gpa, power * 16);
    try appendBe16(&out, gpa, log2);
    try appendBe16(&out, gpa, num * 16 - power * 16);
    const dir = out.items.len;
    try out.appendNTimes(gpa, 0, tables.len * 16);
    var head_at: usize = 0;
    for (tables, 0..) |t, k| {
        const at = out.items.len;
        if (std.mem.eql(u8, t.tag, "head")) head_at = at;
        try out.appendSlice(gpa, t.data);
        while (out.items.len % 4 != 0) try out.append(gpa, 0);
        const rec = dir + k * 16;
        @memcpy(out.items[rec..][0..4], t.tag);
        put32(out.items, rec + 4, checksum(out.items[at..][0..std.mem.alignForward(usize, t.data.len, 4)]));
        put32(out.items, rec + 8, @intCast(at));
        put32(out.items, rec + 12, @intCast(t.data.len));
    }
    put32(out.items, head_at + 8, 0xB1B0AFBA -% checksum(out.items));
    return out.toOwnedSlice(gpa);
}

fn checksum(b: []const u8) u32 {
    var sum: u32 = 0;
    var at: usize = 0;
    while (at + 4 <= b.len) : (at += 4) sum +%= be32(b, at);
    return sum;
}

fn appendBe16(l: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try l.appendSlice(gpa, &b);
}

fn appendBe32(l: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try l.appendSlice(gpa, &b);
}
