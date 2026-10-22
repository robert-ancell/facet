//! HorizontalDivider and VerticalDivider: a thin rule separating content,
//! across (between things above and below) or down (between things beside
//! each other).

const gfx = @import("gfx");
const widget = @import("widget.zig");
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Padding = @import("padding.zig").Padding;
const SizedBox = @import("sized_box.zig").SizedBox;

const Widget = widget.Widget;
const Context = widget.BuildContext;

/// A horizontal divider: a thin line across, between the content above it and
/// the content below it.
///
/// ![The HorizontalDivider example](images/HorizontalDivider.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 240, .child = cx.make(kete.Column{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
///     kete.Text{ .text = "Above" },
///     kete.HorizontalDivider{},
///     kete.Text{ .text = "Below" },
/// }) }) });
/// ```
pub const HorizontalDivider = struct {
    /// How thick the line is, in pixels.
    thickness: f32 = 1,
    /// Space at each end of the line, in pixels.
    inset: f32 = 0,
    /// The line's colour (the theme's variant outline if not given).
    color: ?gfx.Color = null,

    pub fn build(self: *const HorizontalDivider, cx: *Context) Widget {
        return line(cx, false, self.thickness, self.inset, self.color);
    }
};

/// A vertical divider: a thin line down, between the content to its left and
/// the content to its right.
///
/// ![The VerticalDivider example](images/VerticalDivider.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .height = 40, .child = cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
///     kete.Text{ .text = "Left" },
///     kete.VerticalDivider{},
///     kete.Text{ .text = "Right" },
/// }) }) });
/// ```
pub const VerticalDivider = struct {
    /// How thick the line is, in pixels.
    thickness: f32 = 1,
    /// Space at each end of the line, in pixels.
    inset: f32 = 0,
    /// The line's colour (the theme's variant outline if not given).
    color: ?gfx.Color = null,

    pub fn build(self: *const VerticalDivider, cx: *Context) Widget {
        return line(cx, true, self.thickness, self.inset, self.color);
    }
};

/// The line of a divider, `thickness` across its width (`vertical`) or its
/// height, with `inset` at each end of its length.
fn line(cx: *Context, vertical: bool, thickness: f32, inset: f32, color: ?gfx.Color) Widget {
    const rule = cx.make(RoundedBox{ .color = color orelse cx.theme().outline_variant });
    const sized = cx.make(if (vertical)
        SizedBox{ .width = thickness, .child = rule }
    else
        SizedBox{ .height = thickness, .child = rule });
    if (inset <= 0) return sized;
    return cx.make(Padding{
        .padding = if (vertical) .symmetric(0, inset) else .symmetric(inset, 0),
        .child = sized,
    });
}
