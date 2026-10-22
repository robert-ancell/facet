//! Snackbar: a brief notification bar at the bottom of the
//! window, with a message, an optional action button and a dismiss button.

const a11y = @import("accessibility.zig");
const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const IconButton = @import("icon_button.zig").IconButton;
const Overlay = @import("overlay.zig").Overlay;
const Padding = @import("padding.zig").Padding;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;
const TextButton = @import("button.zig").TextButton;

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Context = widget.BuildContext;
const Callback = widget.Callback;

/// A snackbar: a short message at the bottom of the screen, with
/// an optional action.
///
/// ![The Snackbar example](images/Snackbar.png)
///
/// ```zig
/// return cx.make(kete.Snackbar{
///     .message = "Message archived",
///     .action_label = "Undo",
///     .on_action = .of(state, State.save),
///     .on_dismiss = .of(state, State.save),
/// });
/// ```
pub const Snackbar = struct {
    /// What it says.
    message: []const u8,
    /// The text of an action button (none, if empty).
    action_label: []const u8 = "",
    /// Called when the action button is pressed.
    on_action: ?Callback = null,
    /// Called when the snackbar is dismissed.
    on_dismiss: ?Callback = null,
    /// Its width, in pixels (as wide as its message needs, if not given).
    width: ?f32 = null,
    /// Optional content to overlay the snackbar at the bottom of.
    child: ?Widget = null,

    pub const min_height = 48;

    pub fn accessible(self: *const Snackbar, _: *Node) ?a11y.Info {
        // A message that is not urgent: a status (an alert is for those
        // that are).
        return .{ .role = .status, .label = self.message };
    }

    pub fn build(self: *const Snackbar, cx: *Context) Widget {
        if (self.message.len == 0) {
            if (self.child) |under| return cx.make(Overlay{ .children = &.{under} });
            return cx.make(SizedBox.empty);
        }
        const t = cx.theme();

        var items: [3]Widget = undefined;
        var count: usize = 0;

        items[count] = cx.make(Text{
            .text = self.message,
            .style = .{ .size = t.body_size, .color = t.on_surface },
            .wrap = false,
            .ellipsis = true,
        });
        count += 1;

        if (self.action_label.len > 0) {
            items[count] = cx.make(TextButton{
                .label = self.action_label,
                .on_press = self.on_action,
            });
            count += 1;
        }

        if (self.on_dismiss) |dismiss| {
            items[count] = cx.make(IconButton{
                .icon = .close,
                .size = 32,
                .icon_size = 18,
                .on_press = dismiss,
            });
            count += 1;
        }

        const right_pad: f32 = if (self.on_dismiss != null or self.action_label.len > 0) 8 else 16;
        const row = cx.make(Padding{
            .padding = .{ .left = 16, .right = right_pad, .top = 4, .bottom = 4 },
            .child = cx.make(SnackbarRow{
                .expand_msg = self.width != null,
                .children = items[0..count],
            }),
        });

        const sized = if (self.width) |w|
            cx.make(SizedBox{ .width = w, .child = cx.make(ConstrainedBox{ .constraints = .{ .min_h = min_height }, .child = row }) })
        else
            cx.make(ConstrainedBox{ .constraints = .{ .min_w = 240, .min_h = min_height }, .child = row });

        const bar = cx.make(RoundedBox{
            .color = t.surface_container_highest,
            .border_color = t.outline_variant,
            .radius = .all(8),
            .child = sized,
        });

        if (self.child) |under| {
            return cx.make(Overlay{
                .children = cx.makeAll(.{
                    under,
                    Align{
                        .alignment = .bottom_center,
                        .child = cx.make(Padding{ .padding = .all(16), .child = bar }),
                    },
                }),
            });
        }
        return bar;
    }
};

const SnackbarRow = struct {
    expand_msg: bool = false,
    spacing: f32 = 8,
    children: []const Widget = &.{},

    pub fn layout(self: *const SnackbarRow, n: *Node, c: Constraints) Size {
        const count = n.childCount();
        if (count == 0) return c.smallest();
        var trailing_w: f32 = 0;
        var cross_size: f32 = 0;
        if (count > 1) {
            for (n.children.items[1..]) |ch| {
                const s = ch.layout(.{ .min_w = 0, .max_w = geometry.inf, .min_h = 0, .max_h = c.max_h });
                trailing_w += self.spacing + s.w;
                cross_size = @max(cross_size, s.h);
            }
        }
        const avail_w = if (c.boundedWidth()) @max(c.max_w - trailing_w, 0) else geometry.inf;
        const min_msg_w = if (self.expand_msg and c.boundedWidth()) avail_w else @min(@max(c.min_w - trailing_w, 0), avail_w);
        const msg_s = n.child(0).layout(.{ .min_w = min_msg_w, .max_w = avail_w, .min_h = 0, .max_h = c.max_h });
        cross_size = @max(cross_size, msg_s.h);

        const main_size = std.math.clamp(msg_s.w + trailing_w, c.min_w, c.max_w);
        const final_cross = std.math.clamp(cross_size, c.min_h, c.max_h);

        var pos: f32 = 0;
        for (n.children.items) |ch| {
            const s = ch.size;
            ch.place(pos, (final_cross - s.h) / 2);
            pos += s.w + self.spacing;
        }
        return .{ .w = main_size, .h = final_cross };
    }

    pub fn minSize(self: *const SnackbarRow, n: *Node, c: Constraints) Size {
        const count = n.childCount();
        if (count == 0) return c.smallest();
        var trailing_w: f32 = 0;
        var cross_size: f32 = 0;
        if (count > 1) {
            for (n.children.items[1..]) |ch| {
                const s = ch.minSize(.{ .min_w = 0, .max_w = geometry.inf, .min_h = 0, .max_h = c.max_h });
                trailing_w += self.spacing + s.w;
                cross_size = @max(cross_size, s.h);
            }
        }
        const avail_w = if (c.boundedWidth()) @max(c.max_w - trailing_w, 0) else geometry.inf;
        const msg_s = n.child(0).minSize(.{ .min_w = 0, .max_w = avail_w, .min_h = 0, .max_h = c.max_h });
        cross_size = @max(cross_size, msg_s.h);
        return c.constrain(.{ .w = msg_s.w + trailing_w, .h = cross_size });
    }
};
