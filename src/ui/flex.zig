//! Row and Column (both `Flex`): children one after another, left to
//! right or top to bottom.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Expanded = @import("expanded.zig").Expanded;

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.Node;

pub const MainAxisAlignment = enum { start, center, end, space_between, space_around, space_evenly };
pub const CrossAxisAlignment = enum { start, center, end, stretch };
pub const MainAxisSize = enum {
    /// Just the children.
    min,
    /// All the space there is (if bounded).
    max,
};

pub const Row = Flex(.horizontal);
pub const Column = Flex(.vertical);

pub const Axis = enum { horizontal, vertical };

/// Children one after another, left to right (`Row`) or top to bottom
/// (`Column`).
pub fn Flex(comptime axis: Axis) type {
    return struct {
        const Self = @This();

        children: []const Widget = &.{},
        main_axis_alignment: MainAxisAlignment = .start,
        cross_axis_alignment: CrossAxisAlignment = .center,
        main_axis_size: MainAxisSize = .max,
        /// Space between children.
        spacing: f32 = 0,

        fn main(s: Size) f32 {
            return if (axis == .horizontal) s.w else s.h;
        }

        fn cross(s: Size) f32 {
            return if (axis == .horizontal) s.h else s.w;
        }

        fn constraints(min_main: f32, max_main: f32, min_cross: f32, max_cross: f32) Constraints {
            return if (axis == .horizontal)
                .{ .min_w = min_main, .max_w = max_main, .min_h = min_cross, .max_h = max_cross }
            else
                .{ .min_w = min_cross, .max_w = max_cross, .min_h = min_main, .max_h = max_main };
        }

        fn sized(m: f32, x: f32) Size {
            return if (axis == .horizontal) .{ .w = m, .h = x } else .{ .w = x, .h = m };
        }

        fn flexOf(ch: *const Node) f32 {
            const e = ch.widget.as(Expanded) orelse return 0;
            return if (std.math.isFinite(e.flex) and e.flex > 0) e.flex else 0;
        }

        pub fn layout(self: *const Self, n: *Node, c: Constraints) Size {
            const max_main = if (axis == .horizontal) c.max_w else c.max_h;
            const min_main = if (axis == .horizontal) c.min_w else c.min_h;
            const max_cross = if (axis == .horizontal) c.max_h else c.max_w;
            const min_cross = if (axis == .horizontal) c.min_h else c.min_w;
            const bounded = std.math.isFinite(max_main);
            const stretch = self.cross_axis_alignment == .stretch and std.math.isFinite(max_cross);
            const count = n.childCount();
            const spacing = if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
            const gaps = spacing * @as(f32, @floatFromInt(if (count > 0) count - 1 else 0));
            const cross_min: f32 = if (stretch) max_cross else 0;

            // Children without flex first (all of them, if unbounded).
            var total_flex: f32 = 0;
            var used: f32 = gaps;
            var cross_size: f32 = 0;
            for (n.children.items) |ch| {
                const flex = flexOf(ch);
                if (flex > 0 and bounded) {
                    total_flex += flex;
                    continue;
                }
                const s = ch.layout(constraints(0, geometry.inf, cross_min, max_cross));
                used += main(s);
                cross_size = @max(cross_size, cross(s));
            }
            // Then the rest of the space, shared.
            if (total_flex > 0) {
                const free = @max(max_main - used, 0);
                for (n.children.items) |ch| {
                    const flex = flexOf(ch);
                    if (flex == 0) continue;
                    const share = free * flex / total_flex;
                    const s = ch.layout(constraints(share, share, cross_min, max_cross));
                    used += main(s);
                    cross_size = @max(cross_size, cross(s));
                }
            }

            const main_size = std.math.clamp(if (self.main_axis_size == .max and bounded) max_main else used, min_main, max_main);
            const final_cross = std.math.clamp(if (stretch) max_cross else cross_size, min_cross, max_cross);

            // Where the children go: with too little space, from the start
            // (and they overflow at the end).
            const remaining = main_size - used;
            const k: f32 = @floatFromInt(count);
            var lead: f32 = 0;
            var between: f32 = 0;
            if (remaining > 0) switch (self.main_axis_alignment) {
                .start => {},
                .center => lead = remaining / 2,
                .end => lead = remaining,
                .space_between => between = if (count > 1) remaining / (k - 1) else 0,
                .space_around => {
                    between = remaining / k;
                    lead = between / 2;
                },
                .space_evenly => {
                    between = remaining / (k + 1);
                    lead = between;
                },
            };
            var pos = lead;
            for (n.children.items) |ch| {
                const s = ch.size;
                const off = switch (self.cross_axis_alignment) {
                    .start, .stretch => 0,
                    .center => (final_cross - cross(s)) / 2,
                    .end => final_cross - cross(s),
                };
                if (axis == .horizontal) ch.place(pos, off) else ch.place(off, pos);
                pos += main(s) + spacing + between;
            }
            return sized(main_size, final_cross);
        }
    };
}
