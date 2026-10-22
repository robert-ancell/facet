//! NavigationRail: Material 3's vertical navigation sidebar (compact icon +
//! label pills or extended horizontal rows), with optional badges.

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").WidgetNode;
const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Badge = @import("badge.zig").Badge;
const Align = @import("align.zig").Align;
const Column = @import("flex.zig").Column;
const Decorated = @import("decorated.zig").Decorated;
const Expanded = @import("expanded.zig").Expanded;
const Icon = @import("icon.zig").Icon;
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;
const ValueCallback = widget.ValueCallback;

pub const NavigationRail = struct {
    pub const Item = struct {
        label: []const u8,
        icon: icons.IconName,
        badge: ?u32 = null,
    };

    items: []const Item,
    /// The index of the item shown as selected. The app holds it and shows a
    /// change from the next build.
    selected: usize = 0,
    on_select: ?ValueCallback(usize) = null,
    /// When true, renders full-width horizontal pill rows (like a navigation
    /// drawer/sidebar); when false, renders compact vertical icon+label items.
    extended: bool = true,
    width: ?f32 = null,

    pub const max_items = 16;

    const Pick = struct {
        state: *State,
        index: usize,

        fn press(p: *Pick) void {
            if (p.state.on_select) |cb| cb.call(p.index);
        }
    };

    pub const State = struct {
        on_select: ?ValueCallback(usize) = null,
        picks: [max_items]Pick = undefined,
    };

    pub fn accessible(_: *const NavigationRail, _: *Node) ?a11y.Info {
        return .{ .role = .tablist, .orientation = .vertical };
    }

    pub fn build(self: *const NavigationRail, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        state.on_select = self.on_select;
        const count = @min(self.items.len, max_items);
        const rows = cx.arena.alloc(Widget, count) catch return cx.make(SizedBox.empty);
        for (self.items[0..count], state.picks[0..count], rows, 0..) |item, *pick, *row, i| {
            pick.* = .{ .state = state, .index = i };
            row.* = cx.make(RailDestination{
                .item = item,
                .selected = i == self.selected,
                .extended = self.extended,
                .on_press = if (self.on_select != null) .of(pick, Pick.press) else null,
            }).withKey(i);
        }
        const w = self.width orelse if (self.extended) @as(f32, 190) else @as(f32, 80);
        return cx.make(SizedBox{
            .width = w,
            .child = cx.make(Decorated{
                .color = t.surface_container,
                .child = cx.make(@import("scroll_view.zig").ScrollView{
                    .child = cx.make(Padding{
                        .padding = if (self.extended) .all(12) else .all(8),
                        .child = cx.make(Column{
                            .main_axis_size = .min,
                            .cross_axis_alignment = .stretch,
                            .spacing = 4,
                            .children = rows,
                        }),
                    }),
                }),
            }),
        });
    }
};

const RailDestination = struct {
    item: NavigationRail.Item,
    selected: bool,
    extended: bool,
    on_press: ?Callback,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub fn accessible(self: *const RailDestination, _: *Node) ?a11y.Info {
        return .{ .role = .tab, .label = self.item.label, .selected = self.selected, .activate = self.on_press };
    }

    pub fn build(self: *const RailDestination, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const hovered = self.on_press != null and (state.interaction.hovered or state.interaction.pressed);
        const color = if (self.selected) t.on_surface else t.on_surface_variant;
        const highlight: ?gfx.Color = if (self.selected)
            t.secondary_container
        else if (hovered)
            t.on_surface.withAlpha(if (state.interaction.pressed) 0.12 else 0.08)
        else
            null;

        const raw_icon = cx.make(Icon{ .icon = self.item.icon, .size = 22, .color = color });
        const icon_widget = if (self.item.badge) |b|
            cx.make(Badge{ .count = if (b > 0) b else null, .child = raw_icon })
        else
            raw_icon;

        if (self.extended) {
            const height = 48;
            return cx.make(Pressable{
                .on_press = self.on_press,
                .interaction = &state.interaction,
                .child = cx.make(Decorated{
                    .color = highlight,
                    .radius = .all(height / 2),
                    .child = cx.make(SizedBox{
                        .height = height,
                        .child = cx.make(Padding{
                            .padding = .symmetric(16, 0),
                            .child = cx.make(Row{
                                .cross_axis_alignment = .center,
                                .spacing = 12,
                                .children = cx.makeAll(.{
                                    icon_widget,
                                    Expanded{ .child = cx.make(Text{
                                        .text = self.item.label,
                                        .style = .{ .size = 18, .color = color },
                                        .wrap = false,
                                        .ellipsis = true,
                                    }) },
                                }),
                            }),
                        }),
                    }),
                }),
            });
        }

        const pill = cx.make(Decorated{
            .color = highlight,
            .radius = .all(16),
            .child = cx.make(SizedBox{
                .width = 56,
                .height = 32,
                .child = cx.make(Align.center(icon_widget)),
            }),
        });
        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(Padding{
                .padding = .symmetric(0, 4),
                .child = cx.make(Column{
                    .main_axis_size = .min,
                    .cross_axis_alignment = .center,
                    .spacing = 4,
                    .children = cx.makeAll(.{
                        pill,
                        Text{
                            .text = self.item.label,
                            .style = .{ .size = 12, .color = color },
                            .wrap = false,
                            .ellipsis = true,
                        },
                    }),
                }),
            }),
        });
    }
};
