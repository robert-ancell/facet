//! Icon: a Material icon (see the `icons` module).
//!
//!     cx.make(ui.Icon{ .icon = .folder, .size = 24 })
//!
//! It is `size` square, and draws in the theme's text colour unless given
//! another. Only the icons named in `icons.Icon` exist: add a name there
//! to use another.

const gfx = @import("gfx");
const icons = @import("icons");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Node = widget.Node;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const Icon = struct {
    icon: icons.Icon,
    size: f32 = 24,
    /// The theme's text colour (on_surface) if not given.
    color: ?gfx.Color = null,

    pub fn layout(self: *const Icon, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const Icon, n: *Node, p: *Painter) void {
        // In the middle of the space given, at most as big as it.
        const s = @min(self.size, @min(n.size.w, n.size.h));
        p.icon(self.icon, (n.size.w - s) / 2, (n.size.h - s) / 2, s, self.color orelse n.theme().on_surface);
    }
};
