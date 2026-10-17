//! Center: the child in the middle of the space.

const widget = @import("widget.zig");
const Align = @import("align.zig").Align;

const Widget = widget.Widget;
const Context = widget.Context;

/// The child in the middle of the space (an `Align`).
pub const Center = struct {
    width_factor: ?f32 = null,
    height_factor: ?f32 = null,
    child: ?Widget = null,

    pub fn build(self: *const Center, cx: *Context) Widget {
        return cx.make(Align{ .width_factor = self.width_factor, .height_factor = self.height_factor, .child = self.child });
    }
};
