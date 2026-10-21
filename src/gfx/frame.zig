//! A frame to present (`Frame`): what a presenter needs to draw a window's
//! frame, made by the UI when it has painted one. It says what to draw
//! (the canvases' batches and the GPU draws, in order), what is under it
//! (the clear colour), what changed since the frame before (to show again),
//! and what must be drawn into a buffer of any age for it to show the frame
//! (`repaint`), so whoever presents it needs nothing more from the UI.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const renderer_mod = @import("renderer.zig");

const Canvas = canvas_mod.Canvas;
const Viewport = renderer_mod.Viewport;
const Segment = renderer_mod.Segment;

/// Pixel rectangles (a few: damage is merged into as many as this).
pub const Damage = struct {
    pub const max_rects = 8;

    rects: [max_rects]Viewport = undefined,
    len: u8 = 0,

    pub fn slice(d: *const Damage) []const Viewport {
        return d.rects[0..d.len];
    }

    pub fn add(d: *Damage, v: Viewport) void {
        std.debug.assert(d.len < max_rects);
        d.rects[d.len] = v;
        d.len += 1;
    }
};

pub const Frame = struct {
    /// The most buffer ages whose repaint is known: older buffers are drawn
    /// whole.
    pub const max_ages = 5;

    /// The canvases drawn (to prepare: those of its popups too).
    canvases: []const *const Canvas,
    /// What is drawn, in order.
    segments: []const Segment,
    /// What is under it all (ARGB).
    clear: u32,
    /// What changed since the frame before: what the window shows again.
    damage: Damage = .{},
    /// What must be drawn into a buffer last drawn `age` frames ago for it
    /// to show this frame: `repaints[age]` for `age` up to `ages`, and
    /// `repaints[0]` (all of it) for a new buffer or an older one.
    repaints: [max_ages + 1]Damage = @splat(.{}),
    ages: u8 = 0,

    /// What must be drawn into a buffer last drawn `age` frames ago (1: the
    /// frame before; 0: never, or its contents are unknown).
    pub fn repaint(f: *const Frame, age: u32) []const Viewport {
        return f.repaints[if (age > f.ages) 0 else age].slice();
    }
};

test "a frame's repaint is by its buffer's age, all of it for one too old" {
    var f: Frame = .{ .canvases = &.{}, .segments = &.{}, .clear = 0, .ages = 2 };
    f.repaints[0].add(.{ .width = 100, .height = 100 });
    f.repaints[1].add(.{ .x = 10, .y = 10, .width = 5, .height = 5 });
    f.repaints[2].add(.{ .x = 10, .y = 10, .width = 20, .height = 5 });
    try std.testing.expectEqual(@as(u32, 100), f.repaint(0)[0].width);
    try std.testing.expectEqual(@as(u32, 5), f.repaint(1)[0].width);
    try std.testing.expectEqual(@as(u32, 20), f.repaint(2)[0].width);
    try std.testing.expectEqual(@as(u32, 100), f.repaint(3)[0].width);
}
