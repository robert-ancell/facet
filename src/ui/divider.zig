//! Divider: a thin horizontal or vertical rule separating content.

const gfx = @import("gfx");
const widget = @import("widget.zig");
const Axis = @import("flex.zig").Axis;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Padding = @import("padding.zig").Padding;
const SizedBox = @import("sized_box.zig").SizedBox;

const Widget = widget.Widget;
const Context = widget.BuildContext;

/// Material 3's divider: a thin line between content.
///
/// ![The Divider example](images/Divider.png)
///
/// ```zig
/// return cx.make(facet.SizedBox{ .width = 240, .child = cx.make(facet.Column{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
///     facet.Text{ .text = "Above" },
///     facet.Divider{},
///     facet.Text{ .text = "Below" },
/// }) }) });
/// ```
pub const Divider = struct {
    /// Which way it runs: across (a line between rows), or down.
    axis: Axis = .horizontal,
    /// How thick the line is, in pixels.
    thickness: f32 = 1,
    /// Symmetric inset along the divider's length.
    inset: f32 = 0,
    /// The line's colour (the theme's variant outline if not given).
    color: ?gfx.Color = null,

    pub fn build(self: *const Divider, cx: *Context) Widget {
        const line = cx.make(RoundedBox{ .color = self.color orelse cx.theme().outline_variant });
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
