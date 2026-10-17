//! Divider: a thin horizontal or vertical rule separating content.

const gfx = @import("gfx");
const widget = @import("widget.zig");
const Axis = @import("flex.zig").Axis;
const Decorated = @import("decorated.zig").Decorated;
const Padding = @import("padding.zig").Padding;
const SizedBox = @import("sized_box.zig").SizedBox;

const Widget = widget.Widget;
const Context = widget.Context;

pub const Divider = struct {
    axis: Axis = .horizontal,
    thickness: f32 = 1,
    /// Symmetric inset along the divider's length.
    inset: f32 = 0,
    color: ?gfx.Color = null,

    pub fn build(self: *const Divider, cx: *Context) Widget {
        const line = cx.make(Decorated{ .color = self.color orelse cx.theme().outline_variant });
        const sized = cx.make(switch (self.axis) {
            .horizontal => SizedBox{ .height = self.thickness, .child = line },
            .vertical => SizedBox{ .width = self.thickness, .child = line },
        });
        if (self.inset <= 0) return sized;
        return cx.make(Padding{
            .padding = switch (self.axis) {
                .horizontal => .symmetric(self.inset, 0),
                .vertical => .symmetric(0, self.inset),
            },
            .child = sized,
        });
    }
};
