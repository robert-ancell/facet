//! What the selection controls (checkbox.zig, radio.zig,
//! switch.zig) share.
//!
//! Each control shows the value it is given and reports a change
//! through `on_changed` (the app's state holds the value, and its next
//! build shows the change). Without `on_changed` it is disabled. Each
//! control is a `Pressable` around its mark (a widget that paints it, with
//! a tint under the pointer when hovered or pressed); a row form of it (`SwitchRow`,
//! `CheckboxRow`, `RadioRow`) has its `label` beside the mark, and pressing
//! either toggles it. The control on its own is named for assistive
//! technologies with `Accessible`.

const widget = @import("widget.zig");
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.BuildContext;
const Callback = widget.Callback;
const ValueCallback = widget.ValueCallback;

/// The square a checkbox or radio button takes (room to press it).
pub const target = 40;

/// What each control's state keeps from its last build, so a press (which
/// comes between builds) reports the right change.
pub fn Latest(comptime T: type) type {
    return struct {
        interaction: PointerInteraction = .{},
        value: ?T = null,
        on_changed: ?ValueCallback(T) = null,

        pub fn update(s: *@This(), value: T, on_changed: ?ValueCallback(T)) void {
            s.value = value;
            s.on_changed = on_changed;
        }
    };
}

/// The opacity of the tint under the pointer when it is hovered or pressed.
pub fn layerAlpha(i: PointerInteraction, enabled: bool) f32 {
    if (!enabled) return 0;
    return if (i.pressed) 0.10 else if (i.hovered) 0.08 else 0;
}

/// The control's mark beside its label (if any), pressable as a whole.
pub fn control(cx: *Context, interaction: *PointerInteraction, on_press: ?Callback, mark: Widget, label: []const u8, gap: f32) Widget {
    const t = cx.theme();
    const content = if (label.len == 0) mark else cx.make(Row{
        .fill = false,
        .spacing = gap,
        .children = cx.makeAll(.{
            mark,
            Padding{ .padding = .{ .right = 8 }, .child = cx.make(Text{
                .text = label,
                .style = .{ .color = if (on_press != null) t.on_surface else t.on_surface.withAlpha(0.38) },
                .wrap = false,
            }) },
        }),
    });
    return cx.make(Pressable{ .on_press = on_press, .interaction = interaction, .child = content });
}
