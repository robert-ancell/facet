//! Pressable: calls back when the child is clicked, and says whether the
//! pointer is over it and pressing it (`Interaction`).

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

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
/// and released over it), and keeps `interaction` up to date (for widgets
/// that look different when hovered or pressed: give it their state's).
pub const Pressable = struct {
    on_press: ?Callback = null,
    interaction: ?*Interaction = null,
    child: ?Widget = null,

    pub fn cursor(self: *const Pressable, _: *Node, _: geometry.Point) ?widget.Cursor {
        return if (self.on_press != null) .pointer else null;
    }

    pub fn event(self: *const Pressable, _: *Node, e: Event) bool {
        var dummy: Interaction = .{};
        const i = self.interaction orelse &dummy;
        switch (e) {
            .enter => i.hovered = true,
            .leave => i.hovered = false,
            .press => |p| {
                if (p.button != widget.btn_left or self.on_press == null) return false;
                i.pressed = true;
                return true;
            },
            .release => |r| {
                i.pressed = false;
                if (r.inside) if (self.on_press) |f| f.call();
                return true;
            },
            else => {},
        }
        return false;
    }
};
