//! The keyboard's focus: which widget keys go to, moved from one that
//! takes it to the next with Tab (and back with Shift and Tab), within
//! the open menu or dialog if there is one. A widget takes it if it says
//! so (`pub fn focusable(self, n) bool`): those that can be pressed,
//! sliders, text fields.
//!
//! Focus moved by the keyboard shows (`ring`): Material's focus ring
//! around the widget, which goes when the pointer is next pressed.

const std = @import("std");
const gfx = @import("gfx");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Node = widget.WidgetNode;
const Painter = painter_mod.Painter;

/// Whether `n` takes the focus now (and is laid out, so showing).
pub fn takes(n: *Node) bool {
    if (n.laid_out != n.ui.frame_no) return false;
    const f = n.widget.vtable.focusable orelse return false;
    return f(n.widget.ptr, n);
}

/// The widgets that take the focus under `scope`, in the tree's order.
pub fn collect(under: *Node, out: *std.ArrayList(*Node), gpa: std.mem.Allocator) void {
    if (under.laid_out != under.ui.frame_no) return;
    if (takes(under)) out.append(gpa, under) catch return;
    for (under.children.items) |ch| collect(ch, out, gpa);
}

/// The first widget under `n` (or it) that takes the focus.
pub fn first(n: *Node) ?*Node {
    if (n.laid_out != n.ui.frame_no) return null;
    if (takes(n)) return n;
    for (n.children.items) |ch| if (first(ch)) |f| return f;
    return null;
}

/// Whether `a` is `n` or one of its ancestors.
pub fn within(n: *const Node, a: *const Node) bool {
    var at: ?*const Node = n;
    while (at) |x| : (at = x.parent) if (x == a) return true;
    return false;
}

/// Where Tab moves the focus about: the open menu, the topmost open
/// dialog, or the whole UI.
pub fn scope(ui: anytype) ?*Node {
    if (ui.menu != null) if (ui.menu_root) |m| return m;
    const root = ui.root orelse return null;
    // A dialog's surface (not what it is over).
    const d = topDialog(root) orelse return root;
    return findWidget(d, @import("dialog.zig").SurfaceBlocker) orelse d;
}

fn findWidget(n: *Node, comptime T: type) ?*Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findWidget(ch, T)) |f| return f;
    return null;
}

/// The last open dialog in the tree (the one in front), if any.
pub fn topDialog(n: *Node) ?*Node {
    var found: ?*Node = null;
    if (n.widget.as(@import("dialog.zig").Dialog)) |d| if (d.open) {
        found = n;
    };
    for (n.children.items) |ch| if (topDialog(ch)) |f| {
        found = f;
    };
    return found;
}

/// Moves the focus to the next widget that takes it (the previous, if not
/// `forward`), round to the first at the end; true if there was one.
pub fn move(ui: anytype, forward: bool) bool {
    const s = scope(ui) orelse return false;
    var list: std.ArrayList(*Node) = .empty;
    defer list.deinit(ui.gpa);
    collect(s, &list, ui.gpa);
    if (list.items.len == 0) return false;
    const now: ?usize = if (ui.focused) |f| std.mem.indexOfScalar(*Node, list.items, f) else null;
    const n = list.items.len;
    const next = if (now) |i| (if (forward) (i + 1) % n else (i + n - 1) % n) else if (forward) 0 else n - 1;
    show(ui, list.items[next]);
    return true;
}

/// Focuses `n` (moved there by the keyboard, so it shows), scrolled into
/// view.
pub fn show(ui: anytype, n: *Node) void {
    ui.focus(n);
    ui.focus_visible = true;
    reveal(n);
    ui.needs_frame = true;
}

/// Scrolls the scroll views `n` is in so that it shows (with a little
/// room around it).
pub fn reveal(n: *Node) void {
    const ScrollView = @import("scroll_view.zig").ScrollView;
    var at = n.parent;
    while (at) |a| : (at = a.parent) {
        if (a.widget.as(ScrollView) == null) continue;
        const st = a.state(ScrollView.State);
        const top = n.position()[1] - a.position()[1];
        const bottom = top + n.size.h;
        const room = 16;
        if (top < 0) {
            _ = st.scrollTo(st.offset + top - room);
        } else if (bottom > a.size.h) {
            _ = st.scrollTo(st.offset + @min(bottom - a.size.h + room, top));
        }
    }
}

/// Draws Material's focus ring around `n` (in its painter) if it has the
/// focus and that shows: 3 pixels wide, 2 outside it (or inside, with
/// `inset`, for one that fills its space), its corners `radius` (null:
/// round, half its height).
pub fn ring(n: *Node, p: *Painter, radius: ?f32, inset: bool) void {
    if (n.ui.focused != n or !n.ui.focus_visible) return;
    const width: f32 = 3;
    const gap: f32 = if (inset) -(width + 1) else 2;
    const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
    const box = r.outset(gap + width / 2.0);
    const round = (radius orelse n.size.h / 2) + gap + width / 2.0;
    const t = n.theme();
    p.canvas().strokeRoundedRect(box, .all(@max(round, 0)), width, t.primary);
}
