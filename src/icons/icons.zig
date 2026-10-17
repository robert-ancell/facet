//! Facet's icons: Material Icons (Apache License 2.0), drawn from a font.
//! The bundled icon font has only the icons named in `Icon` (see names.zig
//! and tools/subset_icons.zig), so it is a few kilobytes.
//!
//!     const glyph = icons.codepoint(.folder);
//!     const f = try font.Font.init(icons.font_data);
//!
//! In the toolkit, `ui.Icon` draws one.

const std = @import("std");
const names = @import("names.zig");
const generated = @import("icon_codepoints");

pub const Icon = names.Icon;

/// The icon font: Material Icons with only Facet's icons. Its glyphs fill
/// the em square, with the baseline at the bottom: an icon of size `s` is
/// drawn at font size `s`, with its baseline `s` below its top.
pub const font_data = @embedFile("MaterialIcons.ttf");

/// The character an icon is in the font.
pub fn codepoint(icon: Icon) u21 {
    return generated.codepoints[@backingInt(icon)];
}

/// The icon as UTF-8 text in the icon font.
pub fn text(icon: Icon, buf: *[4]u8) []const u8 {
    const len = std.unicode.utf8Encode(codepoint(icon), buf) catch unreachable;
    return buf[0..len];
}

/// The icon with this name, if it is one of Facet's.
pub fn fromName(name: []const u8) ?Icon {
    return std.meta.stringToEnum(Icon, std.mem.trim(u8, name, " \t\r\n"));
}

const testing = std.testing;
const font = @import("font");

test "every icon is in the font, and nothing else is" {
    const f = try font.Font.init(font_data);
    for (std.enums.values(Icon)) |icon| {
        const g = f.glyphIndex(codepoint(icon));
        try testing.expect(g != 0);
        try testing.expect(f.boundingBox(g) != null);
    }
    // An icon Facet does not include (Material's "pets", U+E91D) is left out.
    try testing.expectEqual(@as(u16, 0), f.glyphIndex(0xe91d));
    // A few kilobytes, not the full font's 350.
    try testing.expect(font_data.len < 64 * 1024);
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("\u{e2c7}", text(.folder, &buf));
    try testing.expectEqual(@as(?Icon, .folder), fromName("folder\n"));
    try testing.expectEqual(@as(?Icon, null), fromName("pets"));
}
