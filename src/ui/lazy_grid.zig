//! LazyGrid: a grid of many items all the same size, of which only those
//! that show are made. With an infinite cell width it is a list: one
//! column of items as wide as it. Like `Grid`, as many cells go in a row as fit; but
//! the items are made by a function, given their index, and only for the
//! rows in view (and a row either side) of the scroll view it is in.
//! Because every cell is the same size, how big the grid is, and where
//! each item goes, is known without making them.
//!
//!     cx.make(ui.ScrollView{ .child = cx.make(ui.LazyGrid{
//!         .count = files.len,
//!         .cell = .{ .w = 128, .h = 124 },
//!         .item = .of(view, View.tile),
//!     }) })
//!
//! The items made are those of the frame before (so they are built with
//! the rest of the tree); if the scroll view shows other rows once laid
//! out, they are made then. Items are matched to their nodes by index,
//! unless the item has a key.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Rect = geometry.Rect;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.Node;
const Context = widget.Context;

pub const LazyGrid = struct {
    count: usize,
    cell: Size,
    /// Space between cells, across and down.
    spacing: f32 = 0,
    item: ItemBuilder,
    /// Rows made beyond those in view, above and below, so a little
    /// scrolling needs nothing made.
    extra_rows: usize = 1,
    /// An item made even when it does not show: one a scroll view is to
    /// reveal (see `ScrollView.reveal`), say.
    keep: ?usize = null,

    /// Makes item `index` (in the frame's arena, with `cx.make`).
    pub const ItemBuilder = struct {
        ctx: *const anyopaque,
        f: *const fn (*const anyopaque, *Context, usize) Widget,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context, usize) Widget) ItemBuilder {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .f = struct {
                fn call(ctx: *const anyopaque, cx: *Context, i: usize) Widget {
                    return f(@as(P, @ptrCast(@alignCast(@constCast(ctx)))), cx, i);
                }
            }.call };
        }
    };

    pub const State = struct {
        /// The items made: from `first` up to `end`, and `kept` (made even
        /// though it does not show).
        first: usize = 0,
        end: usize = 0,
        kept: ?usize = null,
    };

    /// The items made with the rest of the tree: those of the last frame
    /// (and the item to keep).
    pub fn lazyChildren(self: *const LazyGrid, cx: *Context, n: *Node) []const Widget {
        const st = n.state(State);
        st.end = @min(st.end, self.count);
        st.first = @min(st.first, st.end);
        st.kept = self.extra(st.first, st.end);
        return self.make(cx, st.*);
    }

    /// The item to keep, if it is not among those from `first` to `end`.
    fn extra(self: *const LazyGrid, first: usize, end: usize) ?usize {
        const k = self.keep orelse return null;
        return if (k < self.count and (k < first or k >= end)) k else null;
    }

    fn make(self: *const LazyGrid, cx: *Context, st: State) []const Widget {
        const len = st.end - st.first + @intFromBool(st.kept != null);
        const out = cx.arena.alloc(Widget, len) catch return &.{};
        for (out, 0..) |*w, k| {
            const i = self.index(st, k);
            const item = self.item.f(self.item.ctx, cx, i);
            w.* = if (item.key == null) item.withKey(i) else item;
        }
        return out;
    }

    /// The index of the `k`th item made.
    fn index(_: *const LazyGrid, st: State, k: usize) usize {
        return if (k < st.end - st.first) st.first + k else st.kept.?;
    }

    fn gap(self: *const LazyGrid) f32 {
        return if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
    }

    /// A list: one column, its items as wide as it.
    fn isList(self: *const LazyGrid) bool {
        return !std.math.isFinite(self.cell.w);
    }

    fn columns(self: *const LazyGrid, width: f32) usize {
        if (self.isList()) return 1;
        if (!std.math.isFinite(width)) return @max(self.count, 1);
        const cw = @max(self.cell.w, 0);
        return @max(1, @as(usize, @intFromFloat(@max(@floor((width + self.gap()) / (cw + self.gap())), 0))));
    }

    pub fn layout(self: *const LazyGrid, n: *Node, c: Constraints) Size {
        const cols = self.columns(c.max_w);
        const rows = (self.count + cols - 1) / cols;
        const cw = if (self.isList()) 0 else @max(self.cell.w, 0);
        const ch = @max(self.cell.h, 0);
        const used: f32 = @floatFromInt(@min(cols, self.count));
        const r: f32 = @floatFromInt(rows);
        const content: Size = .{
            .w = if (c.boundedWidth()) c.max_w else used * (cw + self.gap()) - (if (self.count > 0) self.gap() else 0),
            .h = r * (ch + self.gap()) - (if (rows > 0) self.gap() else 0),
        };
        const size = c.constrain(content);
        n.size = size;
        self.place(n, cols);
        // In a scroll view, it says what shows once it is laid out (see
        // `realize`); otherwise all of it is made, like a `Grid`'s.
        if (n.ui.scrolling == 0) self.realize(n, .{ .x = 0, .y = 0, .w = content.w, .h = content.h });
        return size;
    }

    pub fn minSize(self: *const LazyGrid, _: *Node, c: Constraints) Size {
        if (self.count == 0) return c.smallest();
        const cw = if (self.isList()) 0 else @max(self.cell.w, 0);
        const ch = @max(self.cell.h, 0);
        return c.constrain(.{ .w = cw, .h = ch });
    }

    /// Lays out the items made, each in its cell.
    fn place(self: *const LazyGrid, n: *Node, cols: usize) void {
        const st = n.state(State);
        const cell: Size = .{ .w = if (self.isList()) n.size.w else @max(self.cell.w, 0), .h = @max(self.cell.h, 0) };
        for (n.children.items, 0..) |child, k| {
            const i = self.index(st.*, k);
            _ = child.layout(.tight(cell));
            const col: f32 = @floatFromInt(i % cols);
            const row: f32 = @floatFromInt(i / cols);
            child.place(col * (cell.w + self.gap()), row * (cell.h + self.gap()));
        }
    }

    /// `visible` (relative to the grid) is what shows: the items in the
    /// rows it covers are made, if they are not already, and laid out.
    pub fn realize(self: *const LazyGrid, n: *Node, visible: Rect) void {
        const cols = self.columns(n.size.w);
        const pitch = @max(self.cell.h, 0) + self.gap();
        var want: State = .{};
        if (visible.h > 0 and visible.w > 0 and pitch > 0 and visible.y + visible.h > 0) {
            const top: usize = @intFromFloat(@max(@floor(visible.y / pitch), 0));
            const bottom: usize = @intFromFloat(@max(@ceil((visible.y + visible.h) / pitch), 0));
            want.first = @min((top -| self.extra_rows) * cols, self.count);
            want.end = @min((bottom + self.extra_rows) * cols, self.count);
        }
        want.kept = self.extra(want.first, want.end);
        const len = want.end - want.first + @intFromBool(want.kept != null);
        const st = n.state(State);
        if (std.meta.eql(st.*, want) and n.children.items.len == len) return;
        st.* = want;
        var cx: Context = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n };
        n.reconcile(self.make(&cx, want));
        if (n.children.items.len != len) {
            // Out of memory: none rather than the wrong ones.
            n.reconcile(&.{});
            st.* = .{};
        }
        self.place(n, cols);
    }
};
