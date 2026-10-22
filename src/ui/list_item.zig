//! ListItem: a list row with a leading icon or widget, a
//! headline, optional supporting text, and a trailing icon, text or widget.

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").WidgetNode;
const std = @import("std");
const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Column = @import("flex.zig").Column;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Expanded = @import("expanded.zig").Expanded;
const Icon = @import("icon.zig").Icon;
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.BuildContext;
const Callback = widget.Callback;
const Color = gfx.Color;

/// A list item: a row with a headline and, optionally, supporting
/// text and things at its start and end.
///
/// ![The ListItem example](images/ListItem.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 320, .child = cx.make(kete.Column{ .fill = false, .children = cx.makeAll(.{
///     kete.ListItem{ .headline = "Photos", .supporting_text = "Jan 9, 2026", .leading_icon = .image, .trailing_icon = .chevron_right, .on_press = .of(state, State.save) },
///     kete.ListItem{ .headline = "Documents", .supporting_text = "Updated yesterday", .leading_icon = .folder, .trailing_text = "12 items", .selected = true, .on_press = .of(state, State.save) },
/// }) }) });
/// ```
pub const ListItem = struct {
    /// The main text.
    headline: []const u8,
    /// A second line of smaller text under it.
    supporting_text: []const u8 = "",
    /// An icon at the start (`leading` is used instead, if given).
    leading_icon: ?icons.IconName = null,
    /// A widget at the start.
    leading: ?Widget = null,
    /// Text at the end (`trailing` is used instead, if given).
    trailing_text: []const u8 = "",
    /// An icon at the end, after the text.
    trailing_icon: ?icons.IconName = null,
    /// A widget at the end (a `Switch`, say).
    trailing: ?Widget = null,
    /// Whether it is shown as selected (a coloured background).
    selected: bool = false,
    /// The corners' radius of its highlight, in pixels.
    radius: f32 = 8,
    /// Called when it is pressed; without it, it cannot be.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub const one_line_height = 52;
    pub const two_line_height = 68;

    pub fn accessible(self: *const ListItem, _: *Node) ?a11y.Info {
        return .{ .role = .listitem, .label = self.headline, .description = self.supporting_text, .selected = if (self.on_press != null) self.selected else null, .activate = self.on_press };
    }

    pub fn build(self: *const ListItem, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const clickable = self.on_press != null;
        const i = state.interaction;
        const layer: f32 = if (!clickable) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;
        const bg: ?Color = if (self.selected)
            t.secondary_container
        else if (layer > 0)
            t.on_surface.withAlpha(layer)
        else
            null;

        var items: [4]Widget = undefined;
        var count: usize = 0;

        if (self.leading) |lead| {
            items[count] = lead;
            count += 1;
        } else if (self.leading_icon) |ic| {
            items[count] = cx.make(Icon{
                .icon = ic,
                .size = 24,
                .color = if (self.selected) t.primary else t.on_surface_variant,
            });
            count += 1;
        }

        const title = cx.make(Text{
            .text = self.headline,
            .style = .{ .size = 16, .color = t.on_surface },
            .wrap = false,
            .ellipsis = true,
        });
        const text_col = if (self.supporting_text.len > 0)
            cx.make(Column{
                .fill = false,
                .cross_axis_alignment = .start,
                .spacing = 2,
                .children = cx.makeAll(.{
                    title,
                    Text{
                        .text = self.supporting_text,
                        .style = .{ .size = 13, .color = t.on_surface_variant },
                        .wrap = false,
                        .ellipsis = true,
                    },
                }),
            })
        else
            title;

        items[count] = cx.make(Expanded{ .child = text_col });
        count += 1;

        if (self.trailing) |tr| {
            items[count] = tr;
            count += 1;
        } else {
            if (self.trailing_text.len > 0) {
                items[count] = cx.make(Text{
                    .text = self.trailing_text,
                    .style = .{ .size = 13, .color = t.on_surface_variant },
                    .wrap = false,
                });
                count += 1;
            }
            if (self.trailing_icon) |ic| {
                items[count] = cx.make(Icon{
                    .icon = ic,
                    .size = 20,
                    .color = t.on_surface_variant,
                });
                count += 1;
            }
        }

        const min_h: f32 = if (self.supporting_text.len > 0) two_line_height else one_line_height;
        const body = cx.make(RoundedBox{
            .color = bg,
            .radius = .all(self.radius),
            .child = cx.make(ConstrainedBox{
                .constraints = .{ .min_h = min_h },
                .child = cx.make(Padding{
                    .padding = .symmetric(16, 6),
                    .child = cx.make(Row{
                        .spacing = 16,
                        .cross_axis_alignment = .center,
                        .children = items[0..count],
                    }),
                }),
            }),
        });
        if (!clickable) return body;
        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .focus_radius = self.radius,
            .child = body,
        });
    }
};
