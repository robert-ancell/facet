//! Pressable: calls back when the child is clicked, and says whether the
//! pointer is over it and pressing it (`Interaction`).

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const keymap = @import("keymap.zig");
const focus = @import("focus.zig");
const Painter = @import("painter.zig").Painter;

const Widget = widget.Widget;
const Node = widget.Node;
const Event = widget.Event;
const Callback = widget.Callback;

/// Whether the pointer is over a widget, and pressing it.
pub const Interaction = struct {
    hovered: bool = false,
    pressed: bool = false,
};

/// Calls `on_press` when the child is clicked (the left button pressed
/// and released over it), or, with the keyboard's focus (which it takes
/// if it can be pressed), when Space or Enter is pressed; and keeps
/// `interaction` up to date (for widgets that look different when hovered
/// or pressed: give it their state's). Focused from the keyboard, it has
/// a focus ring, its corners `focus_radius` (null: round).
pub const Pressable = struct {
    on_press: ?Callback = null,
    interaction: ?*Interaction = null,
    focus_radius: ?f32 = null,
    child: ?Widget = null,

    pub fn focusable(self: *const Pressable, _: *Node) bool {
        return self.on_press != null;
    }

    pub fn paintOver(self: *const Pressable, n: *Node, p: *Painter) void {
        focus.ring(n, p, self.focus_radius, false);
    }

    pub fn cursor(self: *const Pressable, _: *Node, _: geometry.Point) ?widget.PointerCursor {
        return if (self.on_press != null) .pointer else null;
    }

    pub fn event(self: *const Pressable, _: *Node, e: Event) bool {
        var dummy: Interaction = .{};
        const i = self.interaction orelse &dummy;
        switch (e) {
            .enter => i.hovered = true,
            .leave => i.hovered = false,
            .press => |p| {
                if (p.button != .left or self.on_press == null) return false;
                i.pressed = true;
                return true;
            },
            .release => |r| {
                i.pressed = false;
                if (r.inside) if (self.on_press) |f| f.call();
                return true;
            },
            .key => |k| {
                if (k.code != keymap.space and k.code != keymap.enter and k.code != keymap.keypad_enter) return false;
                const f = self.on_press orelse return false;
                if (k.pressed) f.call();
                return true;
            },
            else => {},
        }
        return false;
    }
};
