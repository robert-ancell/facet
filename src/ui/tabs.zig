//! TabBar: Material 3's horizontal tab bar with an active indicator bar and
//! bottom divider.

const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Badge = @import("badge.zig").Badge;
const Center = @import("center.zig").Center;
const Column = @import("flex.zig").Column;
const Decorated = @import("decorated.zig").Decorated;
const Divider = @import("divider.zig").Divider;
const Expanded = @import("expanded.zig").Expanded;
const Icon = @import("icon.zig").Icon;
const Interaction = @import("pressable.zig").Interaction;
const Padding = @import("padding.zig").Padding;
const Painter = @import("painter.zig").Painter;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.Node;
const Callback = widget.Callback;
const ValueCallback = widget.ValueCallback;

pub const Tab = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    badge: ?u32 = null,
};

pub const TabBar = struct {
    tabs: []const Tab,
    selected: usize = 0,
    on_select: ?ValueCallback(usize) = null,
    /// When true, each tab takes an equal share of the bar's width; when
    /// false, each tab is sized to its content.
    expand: bool = true,

    pub const max_tabs = 16;
    pub const height = 48;

    const Pick = struct {
        state: *State,
        index: usize,

        fn press(p: *Pick) void {
            if (p.state.on_select) |cb| cb.call(p.index);
        }
    };

    pub const State = struct {
        on_select: ?ValueCallback(usize) = null,
        picks: [max_tabs]Pick = undefined,
    };

    pub fn build(self: *const TabBar, cx: *Context, state: *State) Widget {
        state.on_select = self.on_select;
        const count = @min(self.tabs.len, max_tabs);
        const children = cx.arena.alloc(Widget, count) catch return cx.make(@import("empty.zig").Empty{});
        for (self.tabs[0..count], state.picks[0..count], children, 0..) |tab, *pick, *child, i| {
            pick.* = .{ .state = state, .index = i };
            const item = cx.make(TabItem{
                .tab = tab,
                .selected = i == self.selected,
                .on_press = if (self.on_select != null) .of(pick, Pick.press) else null,
            }).withKey(i);
            child.* = if (self.expand) cx.make(Expanded{ .child = item }) else item;
        }
        return cx.make(Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(Row{
                    .main_axis_size = if (self.expand) .max else .min,
                    .children = children,
                }),
                cx.make(Divider{}),
            },
        });
    }
};

const TabItem = struct {
    tab: Tab,
    selected: bool,
    on_press: ?Callback,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub fn build(self: *const TabItem, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const hovered = self.on_press != null and (state.interaction.hovered or state.interaction.pressed);
        const color = if (self.selected) t.primary else t.on_surface_variant;
        const layer: f32 = if (!hovered) 0 else if (state.interaction.pressed) 0.12 else 0.08;

        const label = cx.make(Text{
            .text = self.tab.label,
            .style = .{ .size = t.label_size, .color = color },
            .wrap = false,
        });
        var content = if (self.tab.icon) |ic|
            cx.make(Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(Icon{ .icon = ic, .size = 18, .color = color }),
                    label,
                },
            })
        else
            label;

        if (self.tab.badge) |b| {
            content = cx.make(Row{
                .spacing = 6,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    content,
                    cx.make(Badge{ .count = if (b > 0) b else null }),
                },
            });
        }

        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(Decorated{
                .color = if (layer > 0) t.primary.withAlpha(layer) else null,
                .child = cx.make(SizedBox{
                    .height = TabBar.height,
                    .child = cx.make(Padding{
                        .padding = .symmetric(20, 0),
                        .child = cx.make(Center{ .width_factor = 1, .height_factor = 1, .child = content }),
                    }),
                }),
            }),
        });
    }

    pub fn paintOver(self: *const TabItem, n: *Node, p: *Painter) void {
        if (!self.selected) return;
        const t = &n.ui.theme;
        const indicator_w = @max(24, @min(n.size.w - 24, n.size.w * 0.6));
        const x = (n.size.w - indicator_w) / 2;
        p.canvas().fillRoundedRect(
            .{ .x = x, .y = n.size.h - 3, .w = indicator_w, .h = 3 },
            .{ .tl = 3, .tr = 3, .bl = 0, .br = 0 },
            t.primary,
        );
    }
};
