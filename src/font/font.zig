//! Kete's font renderer: OpenType fonts with TrueType outlines,
//! rasterized with exact-area anti-aliasing and laid out with kerning.
//!
//! * `opentype`: parsing the font (character map, metrics, outlines, GPOS
//!   kerning)
//! * `raster`: rasterizing outlines into coverage masks
//! * `text`: the glyph cache, layout, and drawing into 32-bit pixels
//!
//! Kete includes Fira Sans (SIL Open Font License) and Twemoji Mozilla as
//! optional default fonts (`default_font_data`, `emoji_font_data`); apps may
//! also supply their own font or none at all.
//!
//!     const f = try font.Font.init(font.default_font_data);
//!     var cache = font.GlyphCache.init(gpa);
//!     _ = try font.draw(canvas, &cache, .{ .font = &f, .size = 32 }, x, baseline, "Hello");

pub const opentype = @import("opentype.zig");
pub const raster = @import("raster.zig");
pub const text = @import("text.zig");

pub const Font = opentype.Font;
pub const Canvas = text.Canvas;
pub const GlyphCache = text.GlyphCache;
pub const Style = text.Style;
pub const Layout = text.Layout;
pub const Run = text.Run;
pub const RunCache = text.RunCache;
pub const GlyphBitmap = text.GlyphBitmap;
pub const GlyphBounds = text.GlyphBounds;
pub const glyphBounds = text.glyphBounds;
pub const rasterizeGlyphWith = text.rasterizeGlyphWith;
pub const rasterizeGlyph = text.rasterizeGlyph;
pub const draw = text.draw;
pub const measure = text.measure;

/// The bundled default sans-serif font (Fira Sans Regular). Only included in
/// the final binary if referenced.
pub const default_font_data = @embedFile("FiraSans-Regular.ttf");

/// The bundled default emoji fallback font (Twemoji Mozilla). Only included
/// in the final binary if referenced.
pub const emoji_font_data = @embedFile("TwemojiMozilla.ttf");

/// Default font file name.
pub const default_font_file = "FiraSans-Regular.ttf";

/// Default emoji font file name.
pub const emoji_font_file = "TwemojiMozilla.ttf";

test {
    _ = opentype;
    _ = raster;
    _ = text;
}
