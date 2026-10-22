//! Icon: a Material icon, by its `IconName`.
//!
//!     cx.make(ui.Icon{ .icon = .folder, .size = 24 })
//!
//! It is `size` square, and draws in the theme's text colour unless given
//! another. Only the icons named in `IconName` exist: add a name there
//! to use another. The icons are drawn from a font of only those, which
//! `Icon.font_data` is, with `Icon.codepoint` and `Icon.text` for drawing
//! one yourself.

const gfx = @import("gfx");
const icons = @import("icons");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Node = widget.WidgetNode;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const Icon = struct {
    icon: icons.IconName,
    size: f32 = 24,
    /// The theme's text colour (on_surface) if not given.
    color: ?gfx.Color = null,

    /// The icon font: Material Icons with only the icons `IconName` has. Its
    /// glyphs fill the em square, with the baseline at the bottom: an icon of
    /// size `s` is drawn at font size `s`, with its baseline `s` below its top.
    pub const font_data = icons.font_data;

    /// The character an icon is in the font.
    pub fn codepoint(name: icons.IconName) u21 {
        return icons.codepoint(name);
    }

    /// The icon as UTF-8 text in the icon font.
    pub fn text(name: icons.IconName, buf: *[4]u8) []const u8 {
        return icons.text(name, buf);
    }

    pub fn layout(self: *const Icon, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const Icon, n: *Node, p: *Painter) void {
        // In the middle of the space given, at most as big as it.
        const s = @min(self.size, @min(n.size.w, n.size.h));
        p.icon(self.icon, (n.size.w - s) / 2, (n.size.h - s) / 2, s, self.color orelse n.theme().on_surface);
    }
};
