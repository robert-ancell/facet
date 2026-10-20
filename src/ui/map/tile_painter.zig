//! Drawing a vector tile's shapes where they show in a map view: given in
//! the tile's coordinates, drawn on the flat map, the globe or between
//! (bent to it: long edges are cut into short ones, and what is on the
//! globe's far side is left out, or brought to its edge). A style draws
//! with it, as can an app's own drawing (`MapStyle.Draw.custom`).

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const projection = @import("projection.zig");
const tiles = @import("tiles.zig");

const View = projection.View;
const TileId = tiles.TileId;
const Point = tiles.VectorTile.Point;
const Color = gfx.Color;

/// How a label is drawn.
pub const LabelStyle = struct {
    size: f32 = 12,
    color: Color,
    /// An outline around the letters (to read over anything).
    halo: ?Color = null,
    /// Where the text is from the point.
    anchor: Anchor = .center,
    /// And how much further (in pixels).
    offset: [2]f32 = .{ 0, 0 },

    pub const Anchor = enum { center, left, right, top, bottom };
};

/// The labels drawn in a frame of a map, so that they do not overlap: a
/// label that would is left out.
pub const Labels = struct {
    placed: std.ArrayList(gfx.Rect) = .empty,
    arena: std.mem.Allocator,
    /// The view's size: labels must be in it.
    size: [2]f32,
    font: ?*const font.Font,
    atlas: *gfx.Atlas,

    /// Draws `text` at `at` (in the view) unless it would overlap a label
    /// drawn already or go out of the view; whether it did.
    pub fn place(l: *Labels, canvas: *gfx.Canvas, at: [2]f32, text: []const u8, style: LabelStyle) bool {
        const f = l.font orelse return false;
        if (text.len == 0) return false;
        const fs: font.Style = .{ .font = f, .size = style.size };
        const w = l.atlas.runs.measure(fs, text);
        const h = style.size * 1.2;
        const gap = style.size * 0.4;
        var x = at[0] + style.offset[0];
        var y = at[1] + style.offset[1];
        switch (style.anchor) {
            .center => {
                x -= w / 2;
                y -= h / 2;
            },
            .left => y -= h / 2,
            .right => {
                x -= w;
                y -= h / 2;
            },
            .top => x -= w / 2,
            .bottom => {
                x -= w / 2;
                y -= h;
            },
        }
        const r: gfx.Rect = .{ .x = x - gap / 2, .y = y, .w = w + gap, .h = h };
        if (r.x < 0 or r.y < 0 or r.x + r.w > l.size[0] or r.y + r.h > l.size[1]) return false;
        for (l.placed.items) |p| if (p.intersects(r)) return false;
        l.placed.append(l.arena, r) catch return false;
        const baseline = @round(y + style.size * 0.95);
        if (style.halo) |halo| {
            const d = @max(1, style.size / 12);
            for ([_][2]f32{ .{ -d, 0 }, .{ d, 0 }, .{ 0, -d }, .{ 0, d }, .{ -d, -d }, .{ d, d }, .{ -d, d }, .{ d, -d } }) |o| {
                _ = canvas.drawText(l.atlas, fs, x + o[0], baseline + o[1], text, halo);
            }
        }
        _ = canvas.drawText(l.atlas, fs, x, baseline, text, style.color);
        return true;
    }
};

pub const TilePainter = struct {
    canvas: *gfx.Canvas,
    /// For what is drawn in a frame (the frame's arena).
    arena: std.mem.Allocator,
    view: *const View,
    /// The tile being drawn.
    id: TileId,
    /// Its top left on the flat map (beyond 0 to 1 for a copy of the
    /// world to the east or west), and its width there.
    corner: [2]f64,
    span: f64,
    /// The tile's coordinates' extent (`VectorTile.extent`).
    extent: f32,
    /// The camera's zoom.
    zoom: f64,
    labels: *Labels,

    /// Where `p` (in the tile's coordinates) shows, and whether it does.
    pub fn project(tp: *const TilePainter, p: Point) View.Projected {
        const k = tp.span / tp.extent;
        return tp.view.project(.{ tp.corner[0] + p[0] * k, tp.corner[1] + p[1] * k });
    }

    const Projected = struct { pos: [2]f32, visible: bool };

    /// The longest edge (in the tile's coordinates) drawn straight: on the
    /// flat map, any; bent, about a degree of the globe.
    fn maxStep(tp: *const TilePainter) f32 {
        if (tp.view.flat >= 1) return std.math.inf(f32);
        const per_tile = @as(f32, @floatFromInt(@as(u32, 256) >> @intCast(@min(tp.id.z, 8))));
        return tp.extent / @max(per_tile, 1);
    }

    /// `points` where they show, with long edges cut into short ones
    /// (back to the first point at the end, if `closed` and bent).
    fn projectAll(tp: *const TilePainter, points: []const Point, closed: bool) []Projected {
        var out: std.ArrayList(Projected) = .empty;
        const step = tp.maxStep();
        const n = points.len;
        const edges = if (closed and step < std.math.inf(f32)) n else n -| 1;
        out.ensureTotalCapacity(tp.arena, n + 1) catch return &.{};
        for (0..n) |i| {
            tp.add(&out, points[i]);
            if (i >= edges) continue;
            const a = points[i];
            const b = points[(i + 1) % n];
            const len = @max(@abs(b[0] - a[0]), @abs(b[1] - a[1]));
            if (len <= step) continue;
            const cuts: usize = @intFromFloat(@min(@ceil(len / step), 4096));
            for (1..cuts) |c| {
                const t = @as(f32, @floatFromInt(c)) / @as(f32, @floatFromInt(cuts));
                tp.add(&out, .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t });
            }
        }
        if (edges == n and n > 0) tp.add(&out, points[0]);
        return out.items;
    }

    fn add(tp: *const TilePainter, out: *std.ArrayList(Projected), p: Point) void {
        const q = tp.project(p);
        out.append(tp.arena, .{ .pos = .{ @floatCast(q.pos[0]), @floatCast(q.pos[1]) }, .visible = q.visible }) catch {};
    }

    /// Whether any of `pts` shows in the view, as far as their bounds go.
    fn inView(tp: *const TilePainter, pts: []const [2]f32, margin: f32) bool {
        if (pts.len == 0) return false;
        var lo = pts[0];
        var hi = pts[0];
        for (pts) |p| {
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
        }
        const size = tp.view.size;
        return hi[0] >= -margin and hi[1] >= -margin and lo[0] <= size[0] + margin and lo[1] <= size[1] + margin;
    }

    /// Fills what is inside an odd number of `rings`.
    pub fn fill(tp: *TilePainter, rings: []const []const Point, color: Color) void {
        const out = tp.arena.alloc([]const [2]f32, rings.len) catch return;
        var any = false;
        var all_pts: std.ArrayList([2]f32) = .empty;
        for (rings, out) |r, *o| {
            const proj = tp.projectAll(r, true);
            const pts = tp.arena.alloc([2]f32, proj.len) catch return;
            // Part way to the flat map, what is on the globe's far side is
            // left out (on the globe it is at its edge).
            const keep_hidden = tp.view.flat <= 0;
            var n: usize = 0;
            for (proj) |q| {
                any = any or q.visible;
                if (!q.visible and !keep_hidden) continue;
                pts[n] = q.pos;
                n += 1;
            }
            all_pts.appendSlice(tp.arena, pts[0..n]) catch {};
            o.* = pts[0..n];
        }
        if (!any or !tp.inView(all_pts.items, 1)) return;
        tp.canvas.fillPath(out, color);
    }

    /// Strokes a line `width` pixels wide through `points` (back to the
    /// first, if `closed`).
    pub fn stroke(tp: *TilePainter, points: []const Point, closed: bool, width: f32, color: Color) void {
        const proj = tp.projectAll(points, closed);
        const pts = tp.arena.alloc([2]f32, proj.len) catch return;
        for (proj, pts) |q, *p| p.* = q.pos;
        if (!tp.inView(pts, width)) return;
        const all_visible = for (proj) |q| {
            if (!q.visible) break false;
        } else true;
        if (all_visible) return strokeRun(tp.canvas, pts, closed and tp.view.flat >= 1, width, color);
        // In runs of what shows, each from (and to) the globe's edge (but
        // part way to the flat map, the far side's points are not there).
        const edge: usize = if (tp.view.flat <= 0) 1 else 0;
        var i: usize = 0;
        while (i < proj.len) {
            while (i < proj.len and !proj[i].visible) i += 1;
            if (i == proj.len) break;
            const start = i -| edge;
            while (i < proj.len and proj[i].visible) i += 1;
            const end = @min(i + edge, proj.len);
            strokeRun(tp.canvas, pts[start..end], false, width, color);
        }
    }

    /// Strokes a run of points, in parts as long as the canvas takes.
    fn strokeRun(canvas: *gfx.Canvas, pts: []const [2]f32, closed: bool, width: f32, color: Color) void {
        const max = gfx.geometry.max_points;
        if (pts.len <= max) return canvas.strokePolyline(pts, closed, width, color);
        var i: usize = 0;
        while (i + 1 < pts.len) : (i += max - 1) canvas.strokePolyline(pts[i..@min(i + max, pts.len)], false, width, color);
        if (closed) canvas.strokePolyline(&.{ pts[pts.len - 1], pts[0] }, false, width, color);
    }

    /// A dot at `p`.
    pub fn circle(tp: *TilePainter, p: Point, radius: f32, color: Color) void {
        const q = tp.project(p);
        if (!q.visible) return;
        tp.canvas.fillCircle(.{ @floatCast(q.pos[0]), @floatCast(q.pos[1]) }, radius, color);
    }

    pub fn ring(tp: *TilePainter, p: Point, radius: f32, width: f32, color: Color) void {
        const q = tp.project(p);
        if (!q.visible) return;
        tp.canvas.strokeCircle(.{ @floatCast(q.pos[0]), @floatCast(q.pos[1]) }, radius, width, color);
    }

    /// A label at `p`, unless it would overlap one already drawn (or, on
    /// the globe, be near its edge, where it would be squeezed).
    pub fn label(tp: *TilePainter, p: Point, text: []const u8, style: LabelStyle) void {
        const q = tp.project(p);
        if (!q.visible) return;
        if (tp.view.flat <= 0) {
            const dx = q.pos[0] - tp.view.size[0] / 2;
            const dy = q.pos[1] - tp.view.size[1] / 2;
            const r = tp.view.discRadius() * 0.85;
            if (dx * dx + dy * dy > r * r) return;
        }
        _ = tp.labels.place(tp.canvas, .{ @floatCast(q.pos[0]), @floatCast(q.pos[1]) }, text, style);
    }
};
