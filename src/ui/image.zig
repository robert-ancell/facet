//! Image: pixels (a `gfx.Image`) as big as they are, or made smaller to
//! fit the space given, keeping their shape; never bigger.
//!
//!     cx.make(ui.Image{ .image = &photo })
//!
//! The image must last as long as it is shown.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Node = widget.Node;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const Image = struct {
    image: *const gfx.Image,
    /// How opaque it is drawn.
    opacity: f32 = 1,

    pub fn layout(self: *const Image, _: *Node, c: Constraints) Size {
        const w: f32 = @floatFromInt(self.image.width);
        const h: f32 = @floatFromInt(self.image.height);
        if (w <= 0 or h <= 0) return c.smallest();
        const scale = @min(1, @min(c.max_w / w, c.max_h / h));
        return c.constrain(.{ .w = @round(w * scale), .h = @round(h * scale) });
    }

    pub fn paint(self: *const Image, n: *Node, p: *Painter) void {
        p.canvas().drawImage(self.image, .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, self.opacity);
    }
};
