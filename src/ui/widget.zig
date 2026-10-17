//! Widgets, and the tree of nodes that keeps them between frames.
//!
//! A `Widget` is an immutable description of part of the screen, made
//! fresh every frame (in the frame's arena) from any struct type:
//!
//! * A type with `build` is made of other widgets. If it declares a
//!   `State` type, it is also stateful: the state lives as long as the
//!   widget stays at its place in the tree, and `build` gets it:
//!
//!       const Counter = struct {
//!           pub const State = struct { count: u32 = 0 };
//!           pub fn build(_: *const Counter, cx: *Context, state: *State) Widget { ... }
//!       };
//!
//! * Any other type lays out and paints itself (and its children):
//!   `layout` sizes it within its constraints and places its children,
//!   `paint` draws it, `event` handles pointer events. Each is optional:
//!   by default a widget passes its constraints to its children, stacks
//!   them at its top left and is as big as allowed. Children are found in
//!   a `child: Widget` (or `?Widget`) or a `children: []const Widget`
//!   field, or made by `lazyChildren` (for widgets that make only the
//!   children that show: see `realize` and lazy_grid.zig).
//!
//! A node is a widget's place in the tree. Each frame the new widgets are
//! matched to the nodes of the last (by position and type, or by key), so
//! state and layout carry over; nodes that no longer match are freed.

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const painter_mod = @import("painter.zig");
const runtime = @import("runtime.zig");

const Size = geometry.Size;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Constraints = geometry.Constraints;
const Painter = painter_mod.Painter;
const Ui = runtime.Ui;

pub const Widget = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,
    /// Matches this widget to the same node across frames when siblings
    /// come and go (otherwise matched by position).
    key: ?u64 = null,

    pub fn withKey(w: Widget, key: u64) Widget {
        var out = w;
        out.key = key;
        return out;
    }

    pub fn is(w: Widget, comptime T: type) bool {
        return w.vtable == vtableFor(T);
    }

    /// The widget's value, if it is a `T`.
    pub fn as(w: Widget, comptime T: type) ?*const T {
        return if (w.is(T)) @ptrCast(@alignCast(w.ptr)) else null;
    }

    /// Makes a widget of a value that lives at least until the next frame
    /// is built (see `Context.make` for values made while building).
    pub fn of(comptime T: type, ptr: *const T) Widget {
        return .{ .ptr = ptr, .vtable = vtableFor(T) };
    }
};

/// The pointer shape a widget asks for while the pointer is over it (or
/// while it has captured the pointer).
pub const Cursor = enum {
    default,
    pointer,
    text,
    grab,
    grabbing,
    crosshair,
    move,
    not_allowed,
    wait,
    progress,
    help,
    ew_resize,
    ns_resize,
    nwse_resize,
    nesw_resize,
};

/// A focused text widget's state for `zwp_text_input_v3`.
pub const TextInputInfo = struct {
    surrounding_text: []const u8 = "",
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// Cursor rectangle in the widget's local coordinates (`[x, y, width, height]`).
    cursor_rect: [4]i32 = .{ 0, 0, 1, 20 },
    password: bool = false,
    multiline: bool = false,
    change_cause_other: bool = false,
};

/// What happens to a widget with an `event` function.
pub const Event = union(enum) {
    /// The pointer moved over it (or onto something inside it).
    enter,
    leave,
    /// A button went down over it. Returning true takes the pointer: it
    /// gets the release, wherever that is.
    press: struct { pos: Point, button: u32 },
    release: struct { pos: Point, button: u32, inside: bool },
    /// The pointer moved, over it or while it has the pointer.
    motion: Point,
    /// The wheel turned over it: by `dy` pixels down (and `dx` right).
    /// Returning true says it scrolled; otherwise it goes to the widgets
    /// around it.
    /// `touch`: a finger moved it (by exactly that much: a pan), rather
    /// than a wheel (whose notches may scroll further).
    scroll: struct { pos: Point, dx: f32, dy: f32, touch: bool = false },
    /// It got the keyboard (`Ui.focus`), or lost it.
    focus,
    blur,
    /// A key went down or up while it has the keyboard.
    key: Key,
    /// An input method committed UTF-8 text (`zwp_text_input_v3`).
    text_commit: []const u8,
    /// An input method updated its preedit string (`zwp_text_input_v3`).
    text_preedit: struct { text: []const u8, cursor_begin: i32 = 0, cursor_end: i32 = 0 },
    /// An input method asked to delete bytes around the cursor
    /// (`zwp_text_input_v3`).
    text_delete_surrounding: struct { before_length: u32, after_length: u32 },
    /// A menu is asked for at a point in it: the right button was pressed
    /// there, or the left held down there without moving. Returning true
    /// says it showed one (`Ui.openMenu`).
    context: Point,

    pub const Key = struct {
        /// A Linux key code (see keymap.zig).
        code: u32,
        pressed: bool,
        /// The character it types (on the keyboard `Ui.keyboard`), if
        /// any: none while Control is held.
        char: ?u21,
        /// Modifiers held.
        ctrl: bool = false,
        shift: bool = false,
    };
};

/// The left mouse button (a Linux button code), in `Event.press` and
/// `.release`.
pub const btn_left = 0x110;
pub const btn_right = 0x111;

/// Something to call later, typically a method of a widget's state:
/// `Callback.of(state, State.increment)`.
pub const Callback = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque) void,

    pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr)) void) Callback {
        const P = @TypeOf(ptr);
        return .{ .ctx = @ptrCast(@constCast(ptr)), .f = struct {
            fn call(ctx: *anyopaque) void {
                f(@as(P, @ptrCast(@alignCast(ctx))));
            }
        }.call };
    }

    pub fn call(c: Callback) void {
        c.f(c.ctx);
    }
};

/// A callback given a value (a control's new value, say):
/// `ValueCallback(bool).of(state, State.setLighting)`.
pub fn ValueCallback(comptime T: type) type {
    return struct {
        ctx: *anyopaque,
        f: *const fn (*anyopaque, T) void,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), T) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(@constCast(ptr)), .f = struct {
                fn call(ctx: *anyopaque, v: T) void {
                    f(@as(P, @ptrCast(@alignCast(ctx))), v);
                }
            }.call };
        }

        pub fn call(c: @This(), v: T) void {
            c.f(c.ctx, v);
        }
    };
}

pub const VTable = struct {
    name: []const u8,
    build: ?*const fn (*const anyopaque, *Context, ?*anyopaque) Widget,
    children: *const fn (*const anyopaque) []const Widget,
    layout: ?*const fn (*const anyopaque, *Node, Constraints) Size,
    paint: ?*const fn (*const anyopaque, *Node, *Painter) void,
    paint_over: ?*const fn (*const anyopaque, *Node, *Painter) void,
    event: ?*const fn (*const anyopaque, *Node, Event) bool,
    hit_test: ?*const fn (*const anyopaque, *Node, Point) bool,
    cursor: ?*const fn (*const anyopaque, *Node, Point) ?Cursor,
    text_input: ?*const fn (*const anyopaque, *Node) ?TextInputInfo,
    /// Makes its children (instead of `children`), when the tree is built.
    lazy_children: ?*const fn (*const anyopaque, *Context, *Node) []const Widget,
    /// Told, once laid out in a scroll view, what of it shows (relative to
    /// itself), to make the children there.
    realize: ?*const fn (*const anyopaque, *Node, Rect) void,
    /// Scrolls its child (`pub const scrolls = true`): it tells the
    /// widgets in it what shows (see `Node.realizeIn`).
    scrolls: bool,
    state: ?StateOps,
    /// Shows only what of its children is within its bounds, without
    /// counting the rest as overflow (`pub const clips_children = true`:
    /// a scroll view).
    clips_children: bool,
};

pub const StateOps = struct {
    size: usize,
    alignment: std.mem.Alignment,
    init: *const fn (*const anyopaque, *anyopaque) void,
    deinit: *const fn (*anyopaque) void,
};

/// The vtable of widgets of type `T` (one per type, so it identifies it).
pub fn vtableFor(comptime T: type) *const VTable {
    return &struct {
        const vtable: VTable = makeVTable(T);
    }.vtable;
}

fn makeVTable(comptime T: type) VTable {
    const S = struct {
        fn self(ptr: *const anyopaque) *const T {
            return @ptrCast(@alignCast(ptr));
        }
        fn build(ptr: *const anyopaque, cx: *Context, state: ?*anyopaque) Widget {
            const param_types = @typeInfo(@TypeOf(T.build)).@"fn".param_types;
            if (param_types.len == 3) return T.build(self(ptr), cx, @ptrCast(@alignCast(state.?)));
            return T.build(self(ptr), cx);
        }
        fn children(ptr: *const anyopaque) []const Widget {
            const w = self(ptr);
            if (@hasField(T, "children")) return w.children;
            if (@hasField(T, "child")) {
                if (@FieldType(T, "child") == Widget) return @as(*const [1]Widget, &w.child);
                if (w.child) |*c| return @as(*const [1]Widget, c);
            }
            return &.{};
        }
        fn layout(ptr: *const anyopaque, n: *Node, c: Constraints) Size {
            return T.layout(self(ptr), n, c);
        }
        fn paint(ptr: *const anyopaque, n: *Node, p: *Painter) void {
            T.paint(self(ptr), n, p);
        }
        fn paintOver(ptr: *const anyopaque, n: *Node, p: *Painter) void {
            T.paintOver(self(ptr), n, p);
        }
        fn event(ptr: *const anyopaque, n: *Node, e: Event) bool {
            return T.event(self(ptr), n, e);
        }
        fn hitTest(ptr: *const anyopaque, n: *Node, p: Point) bool {
            return T.hitTest(self(ptr), n, p);
        }
        fn cursor(ptr: *const anyopaque, n: *Node, p: Point) ?Cursor {
            return T.cursor(self(ptr), n, p);
        }
        fn textInput(ptr: *const anyopaque, n: *Node) ?TextInputInfo {
            return T.textInput(self(ptr), n);
        }
        fn lazyChildren(ptr: *const anyopaque, cx: *Context, n: *Node) []const Widget {
            return T.lazyChildren(self(ptr), cx, n);
        }
        fn realize(ptr: *const anyopaque, n: *Node, visible: Rect) void {
            T.realize(self(ptr), n, visible);
        }
        fn initState(ptr: *const anyopaque, state: *anyopaque) void {
            const st: *T.State = @ptrCast(@alignCast(state));
            st.* = if (@hasDecl(T, "initState")) T.initState(self(ptr)) else .{};
        }
        fn deinitState(state: *anyopaque) void {
            if (@hasDecl(T.State, "deinit")) @as(*T.State, @ptrCast(@alignCast(state))).deinit();
        }
    };
    return .{
        .name = @typeName(T),
        .build = if (@hasDecl(T, "build")) S.build else null,
        .children = S.children,
        .layout = if (@hasDecl(T, "layout")) S.layout else null,
        .paint = if (@hasDecl(T, "paint")) S.paint else null,
        .paint_over = if (@hasDecl(T, "paintOver")) S.paintOver else null,
        .event = if (@hasDecl(T, "event")) S.event else null,
        .hit_test = if (@hasDecl(T, "hitTest")) S.hitTest else null,
        .cursor = if (@hasDecl(T, "cursor")) S.cursor else null,
        .text_input = if (@hasDecl(T, "textInput")) S.textInput else null,
        .lazy_children = if (@hasDecl(T, "lazyChildren")) S.lazyChildren else null,
        .realize = if (@hasDecl(T, "realize")) S.realize else null,
        .scrolls = @hasDecl(T, "scrolls") and T.scrolls,
        .clips_children = @hasDecl(T, "clips_children") and T.clips_children,
        .state = if (@hasDecl(T, "State")) .{
            .size = @sizeOf(T.State),
            .alignment = .of(T.State),
            .init = S.initState,
            .deinit = S.deinitState,
        } else null,
    };
}

/// Shown in place of a widget that could not be made (out of memory).
const Missing = struct {
    pub fn layout(_: *const Missing, _: *Node, c: Constraints) Size {
        return c.smallest();
    }
};
const missing: Missing = .{};

/// What `build` functions get: the frame's arena, and the UI.
pub const Context = struct {
    ui: *Ui,
    arena: std.mem.Allocator,
    /// The node being built.
    node: *Node,

    /// A widget of `value`'s type, copied into the frame's arena (with
    /// its `children` slice, so `&.{ a, b }` can be passed directly).
    pub fn make(cx: *Context, value: anytype) Widget {
        const T = @TypeOf(value);
        const p = cx.arena.create(T) catch return Widget.of(Missing, &missing);
        p.* = value;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            switch (@typeInfo(FieldType)) {
                .pointer => |ptr| if (ptr.size == .slice and ptr.attrs.@"const" and ptr.child != u8) {
                    @field(p, field_name) = cx.arena.dupe(ptr.child, @field(value, field_name)) catch &.{};
                },
                else => {},
            }
        }
        return Widget.of(T, p);
    }

    /// Text formatted into the frame's arena.
    pub fn fmt(cx: *Context, comptime f: []const u8, args: anytype) []const u8 {
        return cx.arena.print(f, args) catch "…";
    }

    pub fn theme(cx: *const Context) *const @import("theme.zig").Theme {
        return &cx.ui.theme;
    }

    /// The frame's time, in nanoseconds (for animations).
    pub fn now(cx: *const Context) u64 {
        return cx.ui.now_ns;
    }

    /// Asks for another frame after this one (for animations).
    pub fn requestFrame(cx: *Context) void {
        cx.ui.needs_frame = true;
    }
};

pub const Edges = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn any(e: Edges) bool {
        return e.left > 0 or e.top > 0 or e.right > 0 or e.bottom > 0;
    }
};

/// A widget's place in the tree, kept between frames.
pub const Node = struct {
    ui: *Ui,
    widget: Widget,
    parent: ?*Node = null,
    state_ptr: ?*anyopaque = null,
    children: std.ArrayList(*Node) = .empty,
    /// From the last layout: the size, and where it is in its parent.
    size: Size = .{},
    offset: Point = .{ 0, 0 },
    /// What the widget drew beyond its children (text), if it can be
    /// bigger than the widget (see `setContent`).
    content: ?Rect = null,
    /// How far its children (or content) reach past each edge.
    overflow: Edges = .{},
    /// The frame it was last laid out in.
    laid_out: u64 = 0,
    /// Whatever the widget's layout wants to keep for its paint, in the
    /// frame's arena.
    scratch: ?*anyopaque = null,
    /// What it drew when last painted (to find what changed).
    paint: @import("damage.zig").Painted = .{},

    pub fn child(n: *const Node, i: usize) *Node {
        return n.children.items[i];
    }

    pub fn childCount(n: *const Node) usize {
        return n.children.items.len;
    }

    /// The state of a stateful widget.
    pub fn state(n: *const Node, comptime S: type) *S {
        return @ptrCast(@alignCast(n.state_ptr.?));
    }

    /// Where it goes in its parent (for `layout` functions).
    pub fn place(n: *Node, x: f32, y: f32) void {
        n.offset = .{ x, y };
    }

    /// For widgets that draw more than their children: the area (relative
    /// to the widget) their drawing needs. Overflow is shown if it is
    /// bigger than the widget.
    pub fn setContent(n: *Node, r: Rect) void {
        n.content = r;
    }

    /// Lays the node out within `c` and returns its size. Never fails:
    /// constraints and sizes that make no sense are made to.
    pub fn layout(n: *Node, c_in: Constraints) Size {
        const c = c_in.sanitize();
        n.laid_out = n.ui.frame_no;
        n.content = null;
        n.scratch = null;
        for (n.children.items) |ch| {
            ch.offset = .{ 0, 0 };
            ch.size = .{};
        }
        const want = if (n.widget.vtable.layout) |f| f(n.widget.ptr, n, c) else n.defaultLayout(c);
        n.size = c.sanitizeSize(want);
        if (n.widget.vtable.clips_children) n.overflow = .{} else n.findOverflow();
        return n.size;
    }

    /// Children get the same constraints and go at the top left; the
    /// node is as big as allowed, or as its biggest child if unbounded.
    fn defaultLayout(n: *Node, c: Constraints) Size {
        if (n.children.items.len == 0) return c.biggest();
        var biggest: Size = .{};
        for (n.children.items) |ch| {
            const s = ch.layout(c);
            biggest = .{ .w = @max(biggest.w, s.w), .h = @max(biggest.h, s.h) };
        }
        return c.constrain(biggest);
    }

    fn findOverflow(n: *Node) void {
        var x0: f32 = 0;
        var y0: f32 = 0;
        var x1 = n.size.w;
        var y1 = n.size.h;
        for (n.children.items) |ch| if (ch.laid_out == n.laid_out) {
            x0 = @min(x0, ch.offset[0]);
            y0 = @min(y0, ch.offset[1]);
            x1 = @max(x1, ch.offset[0] + ch.size.w);
            y1 = @max(y1, ch.offset[1] + ch.size.h);
        };
        if (n.content) |r| {
            x0 = @min(x0, r.x);
            y0 = @min(y0, r.y);
            x1 = @max(x1, r.x + r.w);
            y1 = @max(y1, r.y + r.h);
        }
        // Less than half a pixel is rounding, not overflow.
        const over = struct {
            fn f(d: f32) f32 {
                return if (d > 0.5) d else 0;
            }
        }.f;
        n.overflow = .{ .left = over(-x0), .top = over(-y0), .right = over(x1 - n.size.w), .bottom = over(y1 - n.size.h) };
    }

    // --- Building -----------------------------------------------------------

    pub fn create(ui: *Ui, w: Widget) ?*Node {
        const n = ui.gpa.create(Node) catch return null;
        n.* = .{ .ui = ui, .widget = w };
        if (w.vtable.state) |ops| {
            const mem = ui.gpa.rawAlloc(ops.size, ops.alignment, @returnAddress()) orelse {
                ui.gpa.destroy(n);
                return null;
            };
            ops.init(w.ptr, mem);
            n.state_ptr = mem;
        }
        return n;
    }

    /// Frees the node and those below it.
    pub fn destroy(n: *Node) void {
        for (n.children.items) |ch| ch.destroy();
        n.children.deinit(n.ui.gpa);
        n.ui.forget(n);
        n.ui.damage.removed(n);
        if (n.state_ptr) |s| {
            const ops = n.widget.vtable.state.?;
            ops.deinit(s);
            n.ui.gpa.rawFree(@as([*]u8, @ptrCast(s))[0..ops.size], ops.alignment, @returnAddress());
        }
        n.ui.gpa.destroy(n);
    }

    /// Gives the node this frame's widget, builds it, and does the same
    /// for the children.
    pub fn build(n: *Node, w: Widget) void {
        n.widget = w;
        if (w.vtable.build) |f| {
            var cx: Context = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n };
            const built = f(w.ptr, &cx, n.state_ptr);
            n.reconcile(&.{built});
        } else if (w.vtable.lazy_children) |f| {
            var cx: Context = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n };
            n.reconcile(f(w.ptr, &cx, n));
        } else {
            n.reconcile(w.vtable.children(w.ptr));
        }
    }

    /// Matches the children's widgets to the existing child nodes (same
    /// type, and the same key or position), makes nodes for the rest, and
    /// frees the nodes left over. (Widgets that make their children as
    /// they are laid out call it then.)
    pub fn reconcile(n: *Node, widgets: []const Widget) void {
        if (widgets.len == n.children.items.len) {
            var all_match = true;
            for (widgets, n.children.items) |w, ch| {
                if (ch.widget.vtable != w.vtable or ch.widget.key != w.key) {
                    all_match = false;
                    break;
                }
            }
            if (all_match) {
                for (n.children.items, widgets) |ch, w| ch.build(w);
                return;
            }
        }
        const gpa = n.ui.gpa;
        const arena = n.ui.arena();
        // The old children, aside (the list's memory is reused).
        const old_items: []*Node = arena.dupe(*Node, n.children.items) catch blk: {
            for (n.children.items) |o| o.destroy();
            break :blk &.{};
        };
        const old: struct { items: []*Node } = .{ .items = old_items };
        n.children.clearRetainingCapacity();
        // Which old nodes are kept (if this cannot be had, none are).
        const used: []bool = arena.alloc(bool, old.items.len) catch &.{};
        @memset(used, false);
        // The widget each new child gets.
        const matched: []Widget = arena.alloc(Widget, widgets.len) catch &.{};
        n.children.ensureTotalCapacity(gpa, widgets.len) catch {};
        for (widgets, 0..) |w, i| {
            if (n.children.items.len == matched.len) break;
            var found: ?usize = null;
            if (used.len == old.items.len) {
                if (w.key) |key| {
                    for (old.items, 0..) |o, j| if (!used[j] and o.widget.vtable == w.vtable and o.widget.key == key) {
                        found = j;
                        break;
                    };
                } else if (i < old.items.len and !used[i] and old.items[i].widget.vtable == w.vtable and old.items[i].widget.key == null) {
                    found = i;
                }
            }
            const node = if (found) |j| old.items[j] else Node.create(n.ui, w) orelse continue;
            n.children.append(gpa, node) catch {
                if (found == null) node.destroy();
                continue;
            };
            if (found) |j| used[j] = true;
            node.parent = n;
            matched[n.children.items.len - 1] = w;
        }
        for (old.items, 0..) |o, j| if (j >= used.len or !used[j]) o.destroy();
        for (n.children.items, matched[0..n.children.items.len]) |ch, w| ch.build(w);
    }

    // --- Hit testing ----------------------------------------------------------

    /// Adds the nodes under `p` (relative to this node) that handle events
    /// to `path`, deepest first. Returns whether anything here was hit.
    pub fn hitTest(n: *Node, p: Point, path: *std.ArrayList(*Node)) bool {
        if (n.laid_out != n.ui.frame_no) return false;
        if (p[0] < 0 or p[1] < 0 or p[0] >= n.size.w or p[1] >= n.size.h) return false;
        var hit = false;
        var i = n.children.items.len;
        while (i > 0) {
            i -= 1;
            const ch = n.children.items[i];
            if (ch.hitTest(.{ p[0] - ch.offset[0], p[1] - ch.offset[1] }, path)) {
                hit = true;
                break;
            }
        }
        const vt = n.widget.vtable;
        if (!hit) hit = if (vt.hit_test) |f| f(n.widget.ptr, n, p) else (vt.event != null or vt.cursor != null);
        if (hit and (vt.event != null or vt.cursor != null)) path.append(n.ui.gpa, n) catch {};
        return hit;
    }

    /// Tells the widgets that make only the children that show
    /// (`realize`), in it and below, what of them shows: `visible`
    /// (relative to this node). Scroll views below tell their own.
    pub fn realizeIn(n: *Node, visible: Rect) void {
        if (n.laid_out != n.ui.frame_no) return;
        if (n.widget.vtable.realize) |f| return f(n.widget.ptr, n, visible);
        for (n.children.items) |ch| {
            if (ch.widget.vtable.scrolls) continue;
            ch.realizeIn(.{ .x = visible.x - ch.offset[0], .y = visible.y - ch.offset[1], .w = visible.w, .h = visible.h });
        }
    }

    /// Where the node's top left is in the window (as last laid out).
    pub fn position(n: *const Node) Point {
        var p = n.offset;
        var up = n.parent;
        while (up) |u| : (up = u.parent) p = .{ p[0] + u.offset[0], p[1] + u.offset[1] };
        return p;
    }
};
