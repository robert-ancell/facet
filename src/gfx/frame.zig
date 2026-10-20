//! A frame to present (`Frame`): what a presenter needs to draw a window's
//! frame, made by the UI when it has painted one. It says what to draw
//! (the canvases' batches and the GPU draws, in order), what is under it
//! (the clear colour), what changed since the frame before (to show again),
//! and what must be drawn into a buffer of any age for it to show the frame
//! (`repaint`), so whoever presents it needs nothing more from the UI.
//!
//! A frame may be presented while the UI makes the next (on a render
//! thread): then it is made to outlive it (`Frame.owned`), with what the
//! UI changes in place or the app may free copied: the glyph atlas's rows
//! that changed, and the images the presenter does not have yet (it keeps
//! them while they are drawn, as `Residency` says: the same for both).
//! GPU draws are drawn by the UI into images of their own (layers), so the
//! presenter runs none of the app's code.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const renderer_mod = @import("renderer.zig");

const Canvas = canvas_mod.Canvas;
const Image = canvas_mod.Image;
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
    /// Which of the UI's frames it is (its popups' are the same).
    frame_no: u64 = 0,
    /// What it carries to outlive the UI's next frame (null: it is good
    /// only until then).
    owned: ?Owned = null,

    /// What must be drawn into a buffer last drawn `age` frames ago (1: the
    /// frame before; 0: never, or its contents are unknown).
    pub fn repaint(f: *const Frame, age: u32) []const Viewport {
        return f.repaints[if (age > f.ages) 0 else age].slice();
    }
};

/// What a frame made to outlive the UI's next one carries.
pub const Owned = struct {
    /// What made `new_images`' pixels (the presenter frees them with it).
    gpa: std.mem.Allocator,
    /// The frame's canvases, for the presenter to point at its copies of
    /// the atlas and the images.
    canvases: []const *Canvas,
    /// The glyph atlas's rows that changed since the last such frame (all
    /// of them for the first).
    atlas_rows: ?AtlasRows = null,
    /// The images drawn that the presenter does not have, by `Residency`:
    /// their pixels are the presenter's.
    new_images: []const Image = &.{},
};

/// Rows of the glyph atlas: `rows` (whole rows) from row `y0`.
pub const AtlasRows = struct {
    y0: u32,
    rows: []const u8,
};

/// Which images a presenter has: those drawn in the frames of the frame
/// before (or so far in this one). The UI and the presenter keep one each,
/// told the same, so the UI sends only the images the presenter needs.
pub const Residency = struct {
    /// Each image's id, and the frame it was last drawn in.
    last: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    frame_no: u64 = 0,
    prev: u64 = 0,

    pub fn deinit(r: *Residency, gpa: std.mem.Allocator) void {
        r.last.deinit(gpa);
    }

    /// Starts a frame of frame `frame_no` (more than one may be of the
    /// same): the images not drawn in the one before are let go, each
    /// given to `evicted(ctx, id)`.
    pub fn begin(r: *Residency, gpa: std.mem.Allocator, frame_no: u64, ctx: anytype, comptime evicted: fn (@TypeOf(ctx), u64) void) void {
        if (frame_no == r.frame_no) return;
        r.prev = r.frame_no;
        r.frame_no = frame_no;
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(gpa);
        var it = r.last.iterator();
        while (it.next()) |e| if (e.value_ptr.* < r.prev) stale.append(gpa, e.key_ptr.*) catch {};
        for (stale.items) |id| {
            _ = r.last.remove(id);
            evicted(ctx, id);
        }
    }

    /// Whether the presenter has image `id`.
    pub fn has(r: *const Residency, id: u64) bool {
        const l = r.last.get(id) orelse return false;
        return l >= r.prev;
    }

    /// Image `id` is drawn in this frame.
    pub fn use(r: *Residency, gpa: std.mem.Allocator, id: u64) !void {
        try r.last.put(gpa, id, r.frame_no);
    }
};

test "the images a presenter has are those drawn in the frame before, or in this one" {
    const gpa = std.testing.allocator;
    var r: Residency = .{};
    defer r.deinit(gpa);
    const Evicted = struct {
        fn f(list: *std.ArrayList(u64), id: u64) void {
            list.append(gpa, id) catch {};
        }
    };
    var evicted: std.ArrayList(u64) = .empty;
    defer evicted.deinit(gpa);
    r.begin(gpa, 1, &evicted, Evicted.f);
    try std.testing.expect(!r.has(7));
    try r.use(gpa, 7);
    try r.use(gpa, 8);
    try std.testing.expect(r.has(7));
    // The next frame (twice: a popup's, then the window's): both kept.
    r.begin(gpa, 2, &evicted, Evicted.f);
    r.begin(gpa, 2, &evicted, Evicted.f);
    try std.testing.expect(r.has(7) and r.has(8));
    try r.use(gpa, 7);
    // One not drawn in the frame before goes.
    r.begin(gpa, 5, &evicted, Evicted.f);
    try std.testing.expectEqualSlices(u64, &.{8}, evicted.items);
    try std.testing.expect(r.has(7) and !r.has(8));
}

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
