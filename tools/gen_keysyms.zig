//! Makes src/window/keysyms.zig from X11's keysymdef.h: every keysym's name,
//! and the character those that type one type (where that is not the
//! keysym itself). Run it again when keysymdef.h gains keysyms:
//!
//!     zig run tools/gen_keysyms.zig -- /usr/include/X11/keysymdef.h src/window/keysyms.zig

const std = @import("std");

const Name = struct { name: []const u8, keysym: u32 };
const Char = struct { keysym: u32, char: u21 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: gen_keysyms <keysymdef.h> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const header = try cwd.readFileAlloc(init.io, args[1], arena, .limited(4 << 20));

    var names: std.ArrayList(Name) = .empty;
    var chars: std.ArrayList(Char) = .empty;
    var lines = std.mem.tokenizeAny(u8, header, "\r\n");
    while (lines.next()) |line| {
        // #define XK_name 0xvalue  /* U+XXXX DESCRIPTION */
        const prefix = "#define XK_";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var fields = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
        const name = fields.next() orelse continue;
        const value = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, value, "0x")) continue;
        const keysym = std.fmt.parseInt(u32, value[2..], 16) catch continue;
        try names.append(arena, .{ .name = name, .keysym = keysym });
        // Only exact characters ("/* U+..."), not approximate ones ("<U+...>",
        // "(U+...)"), and only where the keysym is not the character.
        const exact = "/* U+";
        const at = std.mem.indexOf(u8, line, exact) orelse continue;
        const hex = line[at + exact.len ..];
        const end = std.mem.indexOfAny(u8, hex, " */") orelse hex.len;
        const char = std.fmt.parseInt(u21, hex[0..end], 16) catch continue;
        const direct = (keysym >= 0x20 and keysym <= 0x7e) or (keysym >= 0xa0 and keysym <= 0xff) or keysym >= 0x01000000;
        if (direct) continue;
        try chars.append(arena, .{ .keysym = keysym, .char = char });
    }
    std.mem.sort(Name, names.items, {}, struct {
        fn lt(_: void, a: Name, b: Name) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    std.mem.sort(Char, chars.items, {}, struct {
        fn lt(_: void, a: Char, b: Char) bool {
            return a.keysym < b.keysym;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\//! Made by tools/gen_keysyms.zig from X11's keysymdef.h: every keysym's
        \\//! name (sorted, for looking up), and the character each of those that
        \\//! type one types, where that is not the keysym itself (sorted by keysym).
        \\
        \\pub const names = [_]struct { []const u8, u32 }{
        \\
    );
    for (names.items) |n| try out.print(arena, "    .{{ \"{s}\", 0x{x} }},\n", .{ n.name, n.keysym });
    try out.appendSlice(arena, "};\n\npub const chars = [_]struct { u32, u21 }{\n");
    var last: ?u32 = null;
    for (chars.items) |c| {
        if (last == c.keysym) continue;
        last = c.keysym;
        try out.print(arena, "    .{{ 0x{x}, 0x{x} }},\n", .{ c.keysym, c.char });
    }
    try out.appendSlice(arena, "};\n");
    const file = try cwd.createFile(init.io, args[2], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, out.items);
}
