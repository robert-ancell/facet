//! Pictures of a map's vector tiles, which `MapView` draws as images: each
//! tile's shapes in a style, drawn once by the software renderer at about
//! the size the tile shows at, so that the frames after draw the picture
//! instead of every shape of every tile again (and send them all to the
//! GPU). Labels are not in them: they are drawn over them, each frame, so
//! that they stay sharp and do not overlap across tiles.
//!
//! A picture takes in the shapes of the tiles around it that reach into it
//! (a line on a tile's edge, half in the next), as drawing them all
//! together would. It is drawn again when the size the tile shows at
//! strays from it, a layer's zoom range is crossed, the tile's shapes or
//! the style change, or (when there is time to spare) once a tile around
//! it that was not there when it was drawn comes. Drawing pictures takes a
//! few milliseconds a frame at most: a tile waiting for its picture is
//! drawn as shapes meanwhile.

const std = @import("std");
const gfx = @import("gfx");
const window_mod = @import("window");
const projection = @import("projection.zig");
const tiles = @import("tiles.zig");
const style_mod = @import("style.zig");
const tile_painter = @import("tile_painter.zig");

const MapTileId = tiles.MapTileId;
const MapVectorTile = tiles.MapVectorTile;
const MapStyle = style_mod.MapStyle;

pub const Pictures = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(MapTileId, *Picture) = .empty,
    /// The style they are drawn in (`styleHash`): those in another go.
    style: u64 = 0,
    /// What they are drawn on.
    canvas: gfx.Canvas,
    /// The frame they were last asked for in, and how long drawing them
    /// took in it.
    frame: u64 = 0,
    spent_ns: u64 = 0,

    /// How far the size a tile shows at may stray from its picture's
    /// before the picture is drawn again (a fraction of it).
    pub const tolerance = 0.15;
    /// The most time spent drawing pictures in a frame.
    pub const budget_ns = 4 * std.time.ns_per_ms;
    /// The most pictures kept: beyond them, those shown longest ago go.
    pub const max_kept = 96;
    /// Tiles shown smaller than this (logical pixels) are drawn as shapes.
    pub const min_size = 16;

    pub const Picture = struct {
        pixels: []u32,
        image: gfx.Image,
        /// The size it was drawn at (logical pixels, at `scale`).
        size: u32,
        scale: u32,
        /// The map's zoom it was drawn for (for the layers' zoom ranges).
        zoom: f64,
        /// The tile's shapes it was drawn from.
        tile: *const MapVectorTile,
        /// Whether all the tiles around it were there.
        complete: bool,
        /// The frame it was last shown in.
        used_frame: u64,
    };

    /// A tile's picture wanted.
    pub const Want = struct {
        id: MapTileId,
        tile: *const MapVectorTile,
        /// The size it shows at, in logical pixels, and the window's scale.
        size: u32,
        scale: u32,
        /// The map's zoom.
        zoom: f64,
        /// What is under the shapes, and the style's layers (those that are
        /// not labels are drawn).
        background: gfx.Color,
        layers: []const MapStyle.Layer,
        /// The tiles around it.
        nearby: MapStyle.Nearby,
        /// For a custom draw that draws text.
        atlas: *gfx.Atlas,
        /// What tells the time (for the budget).
        io: std.Io,
    };

    pub const Got = struct {
        /// The picture to draw, or null to draw the tile as shapes.
        image: ?*const gfx.Image = null,
        /// Another frame is wanted, to draw a picture there was no time for.
        more: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) Pictures {
        return .{ .gpa = gpa, .canvas = .init(gpa) };
    }

    pub fn deinit(p: *Pictures) void {
        p.clear();
        p.entries.deinit(p.gpa);
        p.canvas.deinit();
    }

    fn clear(p: *Pictures) void {
        var it = p.entries.valueIterator();
        while (it.next()) |e| p.free(e.*);
        p.entries.clearRetainingCapacity();
    }

    fn free(p: *Pictures, e: *Picture) void {
        p.gpa.free(e.pixels);
        p.gpa.destroy(e);
    }

    /// Starts frame `frame` (pictures are wanted for it), in the style
    /// `style` (`styleHash`): those in another go, as do those shown
    /// longest ago when there are too many. None is still drawn from: the
    /// frames they were shown in are done.
    pub fn beginFrame(p: *Pictures, frame: u64, style: u64) void {
        if (style != p.style) {
            p.clear();
            p.style = style;
        }
        if (frame == p.frame) return;
        p.frame = frame;
        p.spent_ns = 0;
        while (p.entries.count() > max_kept) {
            var oldest: ?*Picture = null;
            var oldest_id: MapTileId = undefined;
            var it = p.entries.iterator();
            while (it.next()) |kv| if (oldest == null or kv.value_ptr.*.used_frame < oldest.?.used_frame) {
                oldest = kv.value_ptr.*;
                oldest_id = kv.key_ptr.*;
            };
            _ = p.entries.remove(oldest_id);
            p.free(oldest.?);
        }
    }

    /// The picture to draw for a tile: the one kept, if it will do; or one
    /// drawn now, if there is time; or the one kept anyway, if it is near
    /// enough (drawn again when there is time: `more`); or none.
    pub fn get(p: *Pictures, w: Want) Got {
        if (w.size < min_size or w.size * w.scale > gfx.Image.max_size) return .{};
        const kept = p.entries.get(w.id);
        if (kept) |e| {
            const fits = e.scale == w.scale and e.tile == w.tile and
                stray(e.size, w.size) <= tolerance and !crossesZoom(w.layers, e.zoom, w.zoom);
            if (fits and e.complete) return p.use(e);
            if (p.spent_ns < budget_ns) if (p.draw(w)) |new| return p.use(new);
            // Drawn at another size, or without a tile around it: it will
            // do until it is drawn again.
            if (e.scale == w.scale and e.tile == w.tile) {
                var got = p.use(e);
                got.more = !fits;
                return got;
            }
            return .{ .more = true };
        }
        if (p.spent_ns < budget_ns) if (p.draw(w)) |new| return p.use(new);
        return .{ .more = true };
    }

    fn use(p: *Pictures, e: *Picture) Got {
        e.used_frame = p.frame;
        return .{ .image = &e.image };
    }

    /// How far `size` strays from `was`, as a fraction of it.
    fn stray(was: u32, size: u32) f64 {
        return @abs(@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(was)) - 1);
    }

    /// Whether a layer is drawn at one zoom and not the other.
    fn crossesZoom(layers: []const MapStyle.Layer, a: f64, b: f64) bool {
        for (layers) |l| {
            if (l.draw == .label) continue;
            const in_a = a >= l.min_zoom and a <= l.max_zoom;
            const in_b = b >= l.min_zoom and b <= l.max_zoom;
            if (in_a != in_b) return true;
        }
        return false;
    }

    /// Draws the picture of a tile (in place of the one kept), timed
    /// against the frame's budget; null if it could not be.
    fn draw(p: *Pictures, w: Want) ?*Picture {
        const start = window_mod.nowNs(w.io);
        defer p.spent_ns += window_mod.nowNs(w.io) -| start;
        const px = w.size * w.scale;
        const pixels = p.gpa.alloc(u32, @as(usize, px) * px) catch return null;
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const complete = paint(&p.canvas, arena.allocator(), w);
        @memset(pixels, 0xff000000);
        gfx.software.render(&p.canvas, .{ .pixels = pixels, .width = px, .height = px }) catch {
            p.gpa.free(pixels);
            return null;
        };
        const e = p.gpa.create(Picture) catch {
            p.gpa.free(pixels);
            return null;
        };
        e.* = .{
            .pixels = pixels,
            .image = .init(pixels, px, px),
            .size = w.size,
            .scale = w.scale,
            .zoom = w.zoom,
            .tile = w.tile,
            .complete = complete,
            .used_frame = p.frame,
        };
        const slot = p.entries.getOrPut(p.gpa, w.id) catch {
            p.free(e);
            return null;
        };
        if (slot.found_existing) p.free(slot.value_ptr.*);
        slot.value_ptr.* = e;
        return e;
    }

    /// Paints a tile's picture on `canvas`: its background, and the
    /// layers that are not labels across it and the tiles around it (each
    /// layer across them all before the next), within it. Whether all the
    /// tiles around it were there.
    fn paint(canvas: *gfx.Canvas, arena: std.mem.Allocator, w: Want) bool {
        const id = w.id;
        const n: f64 = @floatFromInt(id.count());
        const size: f64 = @floatFromInt(w.size);
        const corner: [2]f64 = .{ @as(f64, @floatFromInt(id.x)) / n, @as(f64, @floatFromInt(id.y)) / n };
        const view = projection.View.init(.{
            .center = projection.fromWorld(.{ corner[0] + 0.5 / n, corner[1] + 0.5 / n }),
            .zoom = @as(f64, @floatFromInt(id.z)) + std.math.log2(size / 256),
        }, .{ size, size }, .flat);
        canvas.beginScaled(w.size, w.size, w.scale);
        const whole: gfx.Rect = .{ .x = 0, .y = 0, .w = @floatCast(size), .h = @floatCast(size) };
        canvas.fillRect(whole, w.background);
        canvas.setClip(whole);
        // No labels: they are drawn over the pictures.
        var labels: tile_painter.Labels = .{ .arena = arena, .area = whole, .font = null, .atlas = w.atlas };
        const base: tile_painter.MapTilePainter = .{ .canvas = canvas, .arena = arena, .view = &view, .id = id, .corner = corner, .span = 1 / n, .extent = w.tile.extent, .zoom = w.zoom, .labels = &labels };
        // The tile and those around it (none beyond the poles; round the
        // world east and west).
        var around: [9]?struct { tp: tile_painter.MapTilePainter, tile: *const MapVectorTile } = @splat(null);
        var complete = true;
        const count: i64 = @intCast(id.count());
        for ([_]i64{ -1, 0, 1 }, 0..) |dy, j| for ([_]i64{ -1, 0, 1 }, 0..) |dx, i| {
            const y = @as(i64, id.y) + dy;
            if (y < 0 or y >= count) continue;
            const other: MapTileId = .{ .z = id.z, .x = @intCast(@mod(@as(i64, id.x) + dx, count)), .y = @intCast(y) };
            const vt = if (dx == 0 and dy == 0) w.tile else w.nearby.get(w.nearby.ctx, other) orelse {
                complete = false;
                continue;
            };
            var tp = base;
            tp.id = other;
            tp.extent = vt.extent;
            tp.corner = .{ corner[0] + @as(f64, @floatFromInt(dx)) / n, corner[1] + @as(f64, @floatFromInt(dy)) / n };
            around[j * 3 + i] = .{ .tp = tp, .tile = vt };
        };
        for (w.layers) |*l| {
            if (l.draw == .label) continue;
            for (&around) |*a| if (a.*) |*t| MapStyle.drawLayer(l, &t.tp, t.tile);
        }
        return complete;
    }
};

/// A hash of what a style draws: its background and layers (their colours,
/// widths, filters and zoom ranges; a custom draw by its function and
/// context), so that pictures drawn in it are kept only while it is the
/// same.
pub fn styleHash(background: gfx.Color, layers: []const MapStyle.Layer) u64 {
    var h: std.hash.Wyhash = .init(0);
    feed(&h, background);
    feed(&h, layers);
    return h.final();
}

fn feed(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| feed(h, @field(v, name)),
        .@"union" => {
            feed(h, @backingInt(std.meta.activeTag(v)));
            switch (v) {
                inline else => |x| feed(h, x),
            }
        },
        .optional => if (v) |x| {
            h.update(&.{1});
            feed(h, x);
        } else h.update(&.{0}),
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                feed(h, v.len);
                if (ptr.child == u8) h.update(v) else for (v) |x| feed(h, x);
            },
            else => feed(h, @intFromPtr(v)),
        },
        .array => for (v) |x| feed(h, x),
        .float, .int, .bool => h.update(std.mem.asBytes(&v)),
        .@"enum" => feed(h, @backingInt(v)),
        .void => {},
        else => @compileError("cannot hash " ++ @typeName(T)),
    }
}

test "a style's hash is its colours and layers" {
    const a = [_]MapStyle.Layer{.{ .source_layer = "water", .draw = .{ .fill = .rgb(0x0000ff) } }};
    const b = [_]MapStyle.Layer{.{ .source_layer = "water", .draw = .{ .fill = .rgb(0x0000fe) } }};
    const c = [_]MapStyle.Layer{.{ .source_layer = "water", .draw = .{ .fill = .rgb(0x0000ff) } }};
    try std.testing.expectEqual(styleHash(.rgb(0xffffff), &a), styleHash(.rgb(0xffffff), &c));
    try std.testing.expect(styleHash(.rgb(0xffffff), &a) != styleHash(.rgb(0xffffff), &b));
    try std.testing.expect(styleHash(.rgb(0xffffff), &a) != styleHash(.rgb(0xfffffe), &a));
}
