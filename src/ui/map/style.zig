//! How a map's vector tiles are drawn: a style, a list of layers drawn
//! in order, each taking the features of one of the tiles' layers (those
//! its filter picks) and drawing them as fills, lines, dots or labels, or
//! however its own function likes. Labels are drawn after everything
//! else, over it, and none overlap another.
//!
//!     const style: ui.MapStyle = .{ .background = .rgb(0xdde8f0), .layers = &.{
//!         .{ .source_layer = "water", .draw = .{ .fill = .rgb(0x9cc0e0) } },
//!         .{ .source_layer = "roads", .filter = .{ .equals = .{ .key = "kind", .value = .{ .string = "major" } } },
//!            .draw = .{ .line = .{ .color = .rgb(0xffffff), .width = 3 } } },
//!         .{ .source_layer = "places", .draw = .{ .label = .{ .color = .rgb(0x202020), .halo = .rgb(0xffffff) } } },
//!     } };

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const projection = @import("projection.zig");
const tiles = @import("tiles.zig");
const tile_painter = @import("tile_painter.zig");
const Theme = @import("../theme.zig").Theme;

const VectorTile = tiles.VectorTile;
const Feature = VectorTile.Feature;
const Value = VectorTile.Value;
const TilePainter = tile_painter.TilePainter;
const Color = gfx.Color;

pub const MapStyle = struct {
    /// Under the tiles: the globe, and wherever there is nothing.
    background: Color,
    layers: []const Layer,

    pub const Layer = struct {
        /// The tiles' layer whose features it draws: every layer's if null.
        source_layer: ?[]const u8 = null,
        /// Which of them it draws: all, if null.
        filter: ?Filter = null,
        /// The zooms it is drawn at (`Camera.zoom`), from `min_zoom` up to
        /// `max_zoom`.
        min_zoom: f32 = 0,
        max_zoom: f32 = std.math.inf(f32),
        draw: Draw,
    };

    pub const Filter = union(enum) {
        /// Those with this property, set to this.
        equals: struct { key: []const u8, value: Value },
        /// Those without it set to this.
        not_equals: struct { key: []const u8, value: Value },
        /// Those with this property at all.
        has: []const u8,
        /// Those this says.
        func: *const fn (*const Feature) bool,

        pub fn matches(f: Filter, feature: *const Feature) bool {
            return switch (f) {
                .equals => |e| if (feature.get(e.key)) |v| v.eql(e.value) else false,
                .not_equals => |e| if (feature.get(e.key)) |v| !v.eql(e.value) else true,
                .has => |key| feature.get(key) != null,
                .func => |func| func(feature),
            };
        }
    };

    pub const Draw = union(enum) {
        /// Polygons, filled.
        fill: Color,
        /// Lines, and polygons' outlines.
        line: Line,
        /// Points, as dots.
        circle: Circle,
        /// Points, lines (at their middle) and polygons (at their first
        /// ring's middle), labelled with a property.
        label: Label,
        /// Anything, drawn by the app.
        custom: Custom,
    };

    pub const Line = struct {
        color: Color,
        width: f32 = 1,
    };

    pub const Circle = struct {
        color: Color,
        radius: f32 = 4,
        outline: ?Color = null,
        outline_width: f32 = 1,
    };

    pub const Label = struct {
        /// The property shown.
        text: []const u8 = "name",
        style: tile_painter.LabelStyle,
    };

    pub const Custom = struct {
        ctx: ?*const anyopaque = null,
        /// Draws a feature, with the painter (in the tile's coordinates).
        f: *const fn (ctx: ?*const anyopaque, tp: *TilePainter, feature: *const Feature) void,
    };

    /// The plain style, in the theme's colours, for a view with none: for
    /// any tiles, every layer's polygons filled, lines and dots drawn, and
    /// features named.
    const plain_layers = struct {
        fn of(t: *const Theme) [4]Layer {
            return .{
                .{ .draw = .{ .fill = t.surface_container_highest } },
                .{ .draw = .{ .line = .{ .color = t.outline, .width = 1 } } },
                .{ .draw = .{ .circle = .{ .color = t.primary, .radius = 3 } } },
                .{ .draw = .{ .label = .{ .style = .{ .size = 12, .color = t.on_surface, .halo = t.surface_container } } } },
            };
        }
    };

    /// Draws `tile`'s shapes, all but labels (`labels` false) or only
    /// those (true).
    pub fn drawTile(s: *const MapStyle, tp: *TilePainter, tile: *const VectorTile, labels: bool) void {
        for (s.layers) |*l| drawLayer(l, tp, tile, labels);
    }

    /// Draws tile `id`'s shapes on `canvas`, flat, `size` pixels across
    /// with its top left at the origin, background and labels too: a
    /// picture of it (to make picture tiles from shapes, say). `arena` is
    /// for what drawing needs.
    pub fn paintTile(s: *const MapStyle, canvas: *gfx.Canvas, arena: std.mem.Allocator, atlas: *gfx.Atlas, f: ?*const font.Font, id: tiles.TileId, tile: *const VectorTile, size: f32) void {
        const n: f64 = @floatFromInt(id.count());
        const corner: [2]f64 = .{ @as(f64, @floatFromInt(id.x)) / n, @as(f64, @floatFromInt(id.y)) / n };
        const zoom = @as(f64, @floatFromInt(id.z)) + std.math.log2(@as(f64, size) / 256);
        const view = projection.View.init(.{
            .center = projection.fromWorld(.{ corner[0] + 0.5 / n, corner[1] + 0.5 / n }),
            .zoom = zoom,
        }, .{ size, size }, .flat);
        canvas.fillRect(.{ .x = 0, .y = 0, .w = size, .h = size }, s.background);
        var labels: tile_painter.Labels = .{ .arena = arena, .size = .{ size, size }, .font = f, .atlas = atlas };
        var tp: TilePainter = .{ .canvas = canvas, .arena = arena, .view = &view, .id = id, .corner = corner, .span = 1 / n, .extent = tile.extent, .zoom = zoom, .labels = &labels };
        s.drawTile(&tp, tile, false);
        s.drawTile(&tp, tile, true);
    }

    /// As `drawTile`, in the plain style (for a view with no style).
    pub fn drawPlain(t: *const Theme, tp: *TilePainter, tile: *const VectorTile, labels: bool) void {
        const layers = plain_layers.of(t);
        for (&layers) |*l| drawLayer(l, tp, tile, labels);
    }

    fn drawLayer(l: *const Layer, tp: *TilePainter, tile: *const VectorTile, labels: bool) void {
        if ((l.draw == .label) != labels) return;
        const zoom: f32 = @floatCast(tp.zoom);
        if (zoom < l.min_zoom or zoom > l.max_zoom) return;
        for (tile.layers) |*tl| {
            if (l.source_layer) |name| if (!std.mem.eql(u8, name, tl.name)) continue;
            for (tl.features) |*f| {
                if (l.filter) |filter| if (!filter.matches(f)) continue;
                drawFeature(l.draw, tp, f);
            }
        }
    }

    fn drawFeature(d: Draw, tp: *TilePainter, f: *const Feature) void {
        switch (d) {
            .fill => |color| if (f.geometry == .polygon) tp.fill(f.geometry.polygon, color),
            .line => |line| switch (f.geometry) {
                .lines => |lines| for (lines) |pts| tp.stroke(pts, false, line.width, line.color),
                .polygon => |rings| for (rings) |pts| tp.stroke(pts, true, line.width, line.color),
                .points => {},
            },
            .circle => |c| if (f.geometry == .points) for (f.geometry.points) |p| {
                tp.circle(p, c.radius, c.color);
                if (c.outline) |o| tp.ring(p, c.radius, c.outline_width, o);
            },
            .label => |lb| {
                var buf: [32]u8 = undefined;
                const text = f.text(lb.text, &buf) orelse return;
                switch (f.geometry) {
                    .points => |pts| for (pts) |p| tp.label(p, text, lb.style),
                    .lines => |lines| if (lines.len > 0 and lines[0].len > 0) tp.label(middle(lines[0]), text, lb.style),
                    .polygon => |rings| if (rings.len > 0 and rings[0].len > 0) tp.label(centre(rings[0]), text, lb.style),
                }
            },
            .custom => |c| c.f(c.ctx, tp, f),
        }
    }

    /// The point half way along a line.
    fn middle(pts: []const VectorTile.Point) VectorTile.Point {
        var total: f32 = 0;
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| total += std.math.hypot(b[0] - a[0], b[1] - a[1]);
        var left = total / 2;
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
            if (len >= left and len > 0) return .{ a[0] + (b[0] - a[0]) * left / len, a[1] + (b[1] - a[1]) * left / len };
            left -= len;
        }
        return pts[0];
    }

    /// The middle of a ring's bounds.
    fn centre(pts: []const VectorTile.Point) VectorTile.Point {
        var lo = pts[0];
        var hi = pts[0];
        for (pts) |p| {
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
        }
        return .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
    }
};

test "filters pick features by their properties" {
    const f: Feature = .{ .geometry = .{ .points = &.{} }, .properties = &.{.{ .key = "kind", .value = .{ .string = "major" } }} };
    const F = MapStyle.Filter;
    try std.testing.expect((F{ .equals = .{ .key = "kind", .value = .{ .string = "major" } } }).matches(&f));
    try std.testing.expect(!(F{ .equals = .{ .key = "kind", .value = .{ .string = "minor" } } }).matches(&f));
    try std.testing.expect((F{ .not_equals = .{ .key = "kind", .value = .{ .string = "minor" } } }).matches(&f));
    try std.testing.expect((F{ .has = "kind" }).matches(&f));
    try std.testing.expect(!(F{ .has = "name" }).matches(&f));
    try std.testing.expectEqual(VectorTile.Point{ 5, 0 }, MapStyle.middle(&.{ .{ 0, 0 }, .{ 10, 0 } }));
}
