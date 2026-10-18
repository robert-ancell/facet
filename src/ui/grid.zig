//! Grid: children in rows of equal cells.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.Node;

/// Children in rows of equal cells, left to right and top to bottom, as
/// many to a row as fit its width (at least one).
pub const Grid = struct {
    children: []const Widget = &.{},
    cell: Size,
    /// Space between cells, across and down.
    spacing: f32 = 0,

    pub fn layout(self: *const Grid, n: *Node, c: Constraints) Size {
        const count = n.childCount();
        const gap = if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
        const cw = @max(self.cell.w, 0);
        const chh = @max(self.cell.h, 0);
        const columns: usize = if (!c.boundedWidth())
            @max(count, 1)
        else
            @max(1, @as(usize, @intFromFloat(@max(@floor((c.max_w + gap) / (cw + gap)), 0))));
        const rows = (count + columns - 1) / columns;
        for (n.children.items, 0..) |ch, i| {
            _ = ch.layout(.tight(.{ .w = cw, .h = chh }));
            const col: f32 = @floatFromInt(i % columns);
            const row: f32 = @floatFromInt(i / columns);
            ch.place(col * (cw + gap), row * (chh + gap));
        }
        const used_columns: f32 = @floatFromInt(@min(columns, count));
        const r: f32 = @floatFromInt(rows);
        return c.constrain(.{
            .w = if (c.boundedWidth()) c.max_w else used_columns * (cw + gap) - (if (count > 0) gap else 0),
            .h = r * (chh + gap) - (if (rows > 0) gap else 0),
        });
    }

    pub fn minSize(self: *const Grid, n: *Node, c: Constraints) Size {
        const count = n.childCount();
        if (count == 0) return c.smallest();
        const gap = if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
        const cw = @max(self.cell.w, 0);
        const chh = @max(self.cell.h, 0);
        if (!c.boundedWidth() or n.ui.scrolling > 0) {
            return c.constrain(.{ .w = cw, .h = chh });
        }
        const columns: usize = @max(1, @as(usize, @intFromFloat(@max(@floor((c.max_w + gap) / (cw + gap)), 0))));
        const rows = (count + columns - 1) / columns;
        const r: f32 = @floatFromInt(rows);
        return c.constrain(.{
            .w = cw,
            .h = r * (chh + gap) - (if (rows > 0) gap else 0),
        });
    }
};
