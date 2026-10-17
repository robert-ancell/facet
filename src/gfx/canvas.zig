//! A 2D canvas: shapes recorded as batches of vertices, ready for the GPU
//! (see `Renderer`) and independent of it.
//!
//! Coordinates are pixels from the target's top left corner. Colours have
//! straight (not premultiplied) alpha, and every shape blends over what is
//! below it.
//!
//! Rounded rectangles are cut into a 3x3 grid. The four corner cells use
//! the `shape` shader, which computes the exact distance to the rounded
//! outline; the edges and the centre are plain triangles (`solid`), whose
//! straight edges are anti-aliased with a fringe. So the costlier shader
//! only runs over the corners, and a stroked rectangle skips its inside.
//!
//! Shapes of one kind are drawn together when nothing of the other kind
//! drawn in between overlaps them, so a list of separate rectangles is two
//! draws in all.

const std = @import("std");
const geometry = @import("geometry.zig");
const shaders = @import("shaders.zig");
const font = @import("font");
const atlas_mod = @import("atlas.zig");

pub const Atlas = atlas_mod.Atlas;

pub const Point = geometry.Point;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    /// From 0xRRGGBB.
    pub fn rgb(hex: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt(hex >> 16 & 0xff)) / 255,
            .g = @as(f32, @floatFromInt(hex >> 8 & 0xff)) / 255,
            .b = @as(f32, @floatFromInt(hex & 0xff)) / 255,
        };
    }

    /// From 0xAARRGGBB.
    pub fn argb(hex: u32) Color {
        var c = rgb(@truncate(hex));
        c.a = @as(f32, @floatFromInt(hex >> 24)) / 255;
        return c;
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        var out = c;
        out.a = a;
        return out;
    }

    /// As 0xAARRGGBB.
    pub fn toArgb(c: Color) u32 {
        const a: u32 = @intFromFloat(@round(std.math.clamp(c.a, 0, 1) * 255));
        const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255));
        const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255));
        const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255));
        return (a << 24) | (r << 16) | (g << 8) | b;
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
    }

    /// The overlap, or null if there is none.
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
    }

    /// Grown by `d` on every side.
    pub fn outset(r: Rect, d: f32) Rect {
        return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
    }
};

/// Corner radii: top left, top right, bottom right, bottom left.
pub const Radii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    pub fn all(r: f32) Radii {
        return .{ .tl = r, .tr = r, .br = r, .bl = r };
    }

    fn max(r: Radii) f32 {
        return @max(@max(r.tl, r.tr), @max(r.br, r.bl));
    }
};

pub const Kind = enum {
    shape,
    solid,
    /// Solid triangles opaque all over, drawn without blending.
    @"opaque",
    text,
    /// An image, from its own texture (`Batch.image`).
    image,
};

/// Pixels to draw: 0xAARRGGBB (straight alpha), row by row. Each has an
/// `id` of its own (from `init`), by which the GPU's copy is found: make a
/// new Image, rather than change the pixels of one, to show others. At
/// most `max_size` pixels across and down (the GPU's limit).
pub const Image = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    id: u64,

    pub const max_size = 2048;

    /// The next id. Images are made on the thread that draws (64-bit
    /// atomics are not there on the Pi Zero's ARMv6).
    var next_id: u64 = 1;

    pub fn init(pixels: []const u32, width: u32, height: u32) Image {
        std.debug.assert(pixels.len == @as(usize, width) * height and width <= max_size and height <= max_size);
        next_id += 1;
        return .{ .pixels = pixels, .width = width, .height = height, .id = next_id - 1 };
    }
};

pub const Batch = struct {
    kind: Kind,
    /// Vertex data, `floatsPerVertex(kind)` floats per vertex, three
    /// vertices per triangle.
    floats: std.ArrayList(f32) = .empty,
    /// For `.image` batches: the image (one per batch).
    image: ?*const Image = null,
    /// Everything drawn in it.
    bounds: Rect,
    /// The parts of `bounds` drawn in, more closely: shapes next to each
    /// other, or level, share one, and the last takes in the rest when
    /// there are `max_areas`. Shapes drawn later only have to come after this batch
    /// if they overlap one (not just `bounds`, which grows to cover
    /// everything between shapes far apart: a grid's icons, say).
    areas: std.ArrayList(Rect) = .empty,
    clip: ?Rect,

    pub const max_areas = 64;

    pub fn vertexCount(b: *const Batch) u32 {
        return @intCast(b.floats.items.len / floatsPerVertex(b.kind));
    }

    /// Whether anything drawn in it may be in `r`.
    pub fn overlaps(b: *const Batch, r: Rect) bool {
        if (!b.bounds.intersects(r)) return false;
        if (b.areas.items.len == 0) return true;
        for (b.areas.items) |a| if (a.intersects(r)) return true;
        return false;
    }

    /// Notes that a shape covering `r` is drawn in it.
    fn cover(b: *Batch, gpa: std.mem.Allocator, r: Rect) void {
        b.bounds = b.bounds.unite(r);
        const items = b.areas.items;
        if (items.len > 0) {
            const last = &items[items.len - 1];
            // Next to, over or level with the last shape (a row of a
            // grid's icons): one area. Out of room, or memory: the last
            // takes it in.
            const level = r.y < last.y + last.h and last.y < r.y + r.h;
            if (level or last.outset(area_gap).intersects(r) or items.len == max_areas) {
                last.* = last.unite(r);
                return;
            }
        }
        b.areas.append(gpa, r) catch {
            if (b.areas.items.len == 0) return;
            const last = &b.areas.items[b.areas.items.len - 1];
            last.* = last.unite(r);
        };
    }

    /// Shapes this close together share an area.
    const area_gap = 2;
};

pub fn floatsPerVertex(kind: Kind) usize {
    return switch (kind) {
        .shape => shaders.shape_floats,
        .solid, .@"opaque" => shaders.solid_floats,
        .text, .image => shaders.text_floats,
    };
}

/// Stroke width meaning "filled".
const fill_stroke = 1e6;

pub const Canvas = struct {
    gpa: std.mem.Allocator,
    width: f32 = 1,
    height: f32 = 1,
    inv_w: f32 = 2,
    inv_h: f32 = 2,
    batches: std.ArrayList(Batch) = .empty,
    /// Batches kept from earlier frames, for their memory.
    spare: std.ArrayList(Batch) = .empty,
    clip: ?Rect = null,
    /// Added to every coordinate (see `setOrigin`).
    origin: Point = .{ 0, 0 },
    /// Set if a shape could not be recorded (out of memory); the frame is
    /// missing it.
    failed: bool = false,
    /// Where the glyphs of the text batches are (see `drawText`).
    atlas: ?*Atlas = null,
    /// If set, every shape drawn is noted in it (see `Record`).
    recorder: ?*Record = null,

    pub fn init(gpa: std.mem.Allocator) Canvas {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Canvas) void {
        for (c.batches.items) |*b| {
            b.floats.deinit(c.gpa);
            b.areas.deinit(c.gpa);
        }
        for (c.spare.items) |*b| {
            b.floats.deinit(c.gpa);
            b.areas.deinit(c.gpa);
        }
        c.batches.deinit(c.gpa);
        c.spare.deinit(c.gpa);
    }

    /// Starts a frame on a target of this size, forgetting the last one.
    pub fn begin(c: *Canvas, width: u32, height: u32) void {
        c.width = @floatFromInt(width);
        c.height = @floatFromInt(height);
        c.inv_w = 2.0 / c.width;
        c.inv_h = 2.0 / c.height;
        // Kept in reverse, so the next frame's batches (popped off the end)
        // get the buffers the same batches had, already big enough.
        var i = c.batches.items.len;
        while (i > 0) {
            i -= 1;
            const b = &c.batches.items[i];
            b.floats.clearRetainingCapacity();
            b.areas.clearRetainingCapacity();
            c.spare.append(c.gpa, b.*) catch {
                b.floats.deinit(c.gpa);
                b.areas.deinit(c.gpa);
            };
        }
        c.batches.clearRetainingCapacity();
        c.clip = null;
        c.origin = .{ 0, 0 };
        c.failed = false;
        c.atlas = null;
        c.recorder = null;
    }

    /// Limits drawing to a rectangle (whole pixels, relative to the
    /// origin), or not at all.
    pub fn setClip(c: *Canvas, clip: ?Rect) void {
        c.clip = if (clip) |r| .{ .x = r.x + c.origin[0], .y = r.y + c.origin[1], .w = r.w, .h = r.h } else null;
    }

    /// Moves the origin: later coordinates are relative to this point (in
    /// the target's pixels).
    pub fn setOrigin(c: *Canvas, origin: Point) void {
        c.origin = origin;
    }

    // --- Shapes -------------------------------------------------------------

    pub fn fillRect(c: *Canvas, r: Rect, color: Color) void {
        c.roundedRect(r, .{}, fill_stroke, color);
    }

    pub fn strokeRect(c: *Canvas, r: Rect, width: f32, color: Color) void {
        c.roundedRect(r, .{}, width, color);
    }

    pub fn fillRoundedRect(c: *Canvas, r: Rect, radii: Radii, color: Color) void {
        c.roundedRect(r, radii, fill_stroke, color);
    }

    /// Strokes the outline inside the rectangle, `width` pixels wide.
    pub fn strokeRoundedRect(c: *Canvas, r: Rect, radii: Radii, width: f32, color: Color) void {
        c.roundedRect(r, radii, width, color);
    }

    pub fn fillCircle(c: *Canvas, center: Point, radius: f32, color: Color) void {
        c.roundedRect(.{ .x = center[0] - radius, .y = center[1] - radius, .w = 2 * radius, .h = 2 * radius }, .all(radius), fill_stroke, color);
    }

    /// Strokes a circle's outline inside its radius.
    pub fn strokeCircle(c: *Canvas, center: Point, radius: f32, width: f32, color: Color) void {
        c.roundedRect(.{ .x = center[0] - radius, .y = center[1] - radius, .w = 2 * radius, .h = 2 * radius }, .all(radius), width, color);
    }

    /// Fills a simple polygon (convex or concave, not self-intersecting).
    pub fn fillPolygon(c: *Canvas, points: []const Point, color: Color) void {
        c.note(.polygon, c.moved(boundsOf(points)).outset(1), .{ c.origin, color }, std.mem.sliceAsBytes(points));
        var sink: SolidSink = .{ .canvas = c, .bounds = c.moved(boundsOf(points)).outset(1), .color = color, .offset = c.origin };
        geometry.fillPolygon(sink.sink(), points);
    }

    /// Strokes a polyline centred on it, with mitred joins and butt ends.
    pub fn strokePolyline(c: *Canvas, points: []const Point, closed: bool, width: f32, color: Color) void {
        c.note(.polyline, c.moved(boundsOf(points)).outset(width * geometry.miter_limit / 2 + 1), .{ c.origin, color, width, closed }, std.mem.sliceAsBytes(points));
        var sink: SolidSink = .{ .canvas = c, .bounds = c.moved(boundsOf(points)).outset(width * geometry.miter_limit / 2 + 1), .color = color, .offset = c.origin };
        geometry.strokePolyline(sink.sink(), points, closed, width);
    }

    // --- Text -----------------------------------------------------------------

    /// Draws one line of text with its baseline at `baseline` (rounded to
    /// a pixel), starting at `x`, with glyphs from `atlas` (every text
    /// batch of a canvas uses the same one). Returns the pen position after
    /// the text. Glyphs that do not fit in the atlas are left out.
    pub fn drawText(c: *Canvas, atlas: *Atlas, style: font.Style, x: f32, baseline: f32, text: []const u8, color: Color) f32 {
        c.atlas = atlas;
        const ox = c.origin[0];
        const base = @round(baseline + c.origin[1]);
        const run = atlas.runs.get(style, text);
        const end = x + if (run) |r| r.width else font.measure(style, text);
        if (color.a <= 0 or text.len == 0) return end;
        c.note(.text, .{ .x = x + ox - style.size, .y = base - 1.5 * style.size, .w = end - x + 2 * style.size, .h = 2.5 * style.size }, .{ @intFromPtr(style.font), @intFromPtr(style.font.fallback), style.size, x + ox, base, color }, text);
        // Glyphs reach about an em above and below the baseline at most.
        const b = c.batchFor(.text, .{ .x = x + ox - style.size, .y = base - 1.5 * style.size, .w = end - x + 2 * style.size, .h = 2.5 * style.size }) orelse return end;
        var l = font.Layout.init(style, text, 0);
        var i: usize = 0;
        while (true) : (i += 1) {
            const item = if (run) |r| (if (i < r.glyphs.len) r.glyphs[i] else break) else l.next() orelse break;
            const quarter: i32 = @intFromFloat(@round(std.math.clamp(item.x + x + ox, -1e6, 1e6) * 4));
            if (item.font.colorLayers(item.glyph)) |layers_init| {
                var layers = layers_init;
                while (layers.next()) |layer| {
                    const lc = if (layer.color) |hex| blk: {
                        const p = Color.argb(hex);
                        break :blk p.withAlpha(p.a * color.a);
                    } else color;
                    if (!c.emitGlyph(b, atlas, item.font, layer.glyph, style.size, quarter, base, lc)) return end;
                }
                continue;
            }
            if (!c.emitGlyph(b, atlas, item.font, item.glyph, style.size, quarter, base, color)) return end;
        }
        return end;
    }

    fn emitGlyph(c: *Canvas, b: *Batch, atlas: *Atlas, f: *const font.Font, glyph: u16, size: f32, quarter: i32, base: f32, color: Color) bool {
        const e = atlas.glyph(f, glyph, size, @intCast(quarter & 3)) orelse return true;
        if (e.w == 0) return true;
        const inv_aw: f32 = 1.0 / @as(f32, @floatFromInt(atlas_mod.width));
        const inv_ah: f32 = 1.0 / @as(f32, @floatFromInt(atlas_mod.height));
        const x0: f32 = @floatFromInt((quarter >> 2) + e.left);
        const y0 = base + @as(f32, @floatFromInt(e.top));
        const x1 = x0 + @as(f32, @floatFromInt(e.w));
        const y1 = y0 + @as(f32, @floatFromInt(e.h));
        const tu0 = @as(f32, @floatFromInt(e.x)) * inv_aw;
        const tv0 = @as(f32, @floatFromInt(e.y)) * inv_ah;
        const tu1 = @as(f32, @floatFromInt(e.x + e.w)) * inv_aw;
        const tv1 = @as(f32, @floatFromInt(e.y + e.h)) * inv_ah;
        const cx0 = c.clipX(x0);
        const cy0 = c.clipY(y0);
        const cx1 = c.clipX(x1);
        const cy1 = c.clipY(y1);
        const out = c.vertices(b, shaders.text_floats, 6) orelse return false;
        const v0 = [shaders.text_floats]f32{ cx0, cy0, tu0, tv0, color.r, color.g, color.b, color.a };
        const v1 = [shaders.text_floats]f32{ cx1, cy0, tu1, tv0, color.r, color.g, color.b, color.a };
        const v2 = [shaders.text_floats]f32{ cx1, cy1, tu1, tv1, color.r, color.g, color.b, color.a };
        const v3 = [shaders.text_floats]f32{ cx0, cy1, tu0, tv1, color.r, color.g, color.b, color.a };
        out[0] = v0;
        out[1] = v1;
        out[2] = v2;
        out[3] = v0;
        out[4] = v2;
        out[5] = v3;
        return true;
    }

    // --- Images -----------------------------------------------------------------

    /// Draws `img` stretched over `dest`, `alpha` opaque. It must last
    /// until the frame is drawn.
    pub fn drawImage(c: *Canvas, img: *const Image, dest_in: Rect, alpha: f32) void {
        const r = c.moved(dest_in);
        if (r.w <= 0 or r.h <= 0 or alpha <= 0 or img.width == 0 or img.height == 0) return;
        c.note(.image, r, .{ img.id, alpha }, "");
        const b = c.batchForImage(img, r) orelse return;
        const corners = [4][4]f32{ .{ r.x, r.y, 0, 0 }, .{ r.x + r.w, r.y, 1, 0 }, .{ r.x + r.w, r.y + r.h, 1, 1 }, .{ r.x, r.y + r.h, 0, 1 } };
        var verts: [4][shaders.text_floats]f32 = undefined;
        for (corners, &verts) |k, *out| out.* = .{ c.clipX(k[0]), c.clipY(k[1]), k[2], k[3], 1, 1, 1, alpha };
        const out = c.vertices(b, shaders.text_floats, 6) orelse return;
        for ([_]usize{ 0, 1, 2, 0, 2, 3 }, out) |k, *o| o.* = verts[k];
    }

    // --- Rounded rectangles --------------------------------------------------

    fn roundedRect(c: *Canvas, r_in: Rect, radii_in: Radii, stroke: f32, color: Color) void {
        const r = c.moved(r_in);
        if (r.w <= 0 or r.h <= 0 or color.a <= 0) return;
        c.note(.rounded_rect, r.outset(1), .{ r, radii_in, stroke, color }, "");
        const hw = r.w / 2;
        const hh = r.h / 2;
        const limit = @min(hw, hh);
        const radii: Radii = .{ .tl = std.math.clamp(radii_in.tl, 0, limit), .tr = std.math.clamp(radii_in.tr, 0, limit), .br = std.math.clamp(radii_in.br, 0, limit), .bl = std.math.clamp(radii_in.bl, 0, limit) };
        const filled = stroke >= fill_stroke;
        // Corner cells: deep enough for the radius, and for the stroke
        // where it turns the corner; at least the edge's half-pixel fade.
        const e = @max(@max(radii.max(), if (filled) 0 else stroke), 0.5);
        const ex = @min(e, hw);
        const ey = @min(e, hh);
        const x0 = r.x;
        const y0 = r.y;
        const x1 = r.x + r.w;
        const y1 = r.y + r.h;
        const cx = r.x + hw;
        const cy = r.y + hh;
        // A pixel of margin outside, for the fade.
        const m = 1;

        const bounds = r.outset(m);
        // Solid parts: the edges between the corners, and the centre.
        if (x1 - ex > x0 + ex or y1 - ey > y0 + ey) {
            {
                var s: SolidSink = .{ .canvas = c, .bounds = bounds, .color = color };
                const out = s.sink();
                // Across an edge (from outside in): faded, solid, then the
                // stroke's inner edge fading again, or the corner cell's
                // depth when filled.
                const band = if (filled) [_]f32{ -0.5, 0.5, 0, 0 } else [_]f32{ -0.5, 0.5, stroke - 0.5, stroke + 0.5 };
                const alphas = [_]f32{ 0, 1, 1, 0 };
                // Top and bottom edges span between the corner columns.
                if (x1 - ex > x0 + ex) {
                    edgeBand(out, .{ x0 + ex, y0 }, .{ x1 - ex, y0 }, .{ 0, 1 }, band, alphas, filled, ey);
                    edgeBand(out, .{ x1 - ex, y1 }, .{ x0 + ex, y1 }, .{ 0, -1 }, band, alphas, filled, ey);
                }
                if (y1 - ey > y0 + ey) {
                    edgeBand(out, .{ x1, y0 + ey }, .{ x1, y1 - ey }, .{ -1, 0 }, band, alphas, filled, ex);
                    edgeBand(out, .{ x0, y1 - ey }, .{ x0, y0 + ey }, .{ 1, 0 }, band, alphas, filled, ex);
                }
                if (filled and x1 - ex > x0 + ex and y1 - ey > y0 + ey) {
                    out.quad(v(x0 + ex, y0 + ey, 1), v(x1 - ex, y0 + ey, 1), v(x1 - ex, y1 - ey, 1), v(x0 + ex, y1 - ey, 1));
                }
            }
        }

        // Corner cells, each with its own radius.
        const b = c.batchFor(.shape, bounds) orelse return;
        const corners = [4]struct { f32, f32, f32, f32, f32 }{
            .{ x0 - m, y0 - m, x0 + ex, y0 + ey, radii.tl },
            .{ x1 - ex, y0 - m, x1 + m, y0 + ey, radii.tr },
            .{ x1 - ex, y1 - ey, x1 + m, y1 + m, radii.br },
            .{ x0 - m, y1 - ey, x0 + ex, y1 + m, radii.bl },
        };
        for (corners) |k| {
            const quad = [4]Point{ .{ k[0], k[1] }, .{ k[2], k[1] }, .{ k[2], k[3] }, .{ k[0], k[3] } };
            var verts: [4][shaders.shape_floats]f32 = undefined;
            for (quad, &verts) |p, *out| out.* = .{
                c.clipX(p[0]), c.clipY(p[1]),
                p[0] - cx,     p[1] - cy,
                hw,            hh,
                k[4],          stroke,
                color.r,       color.g,
                color.b,       color.a,
            };
            c.append(b, &.{ verts[0], verts[1], verts[2], verts[0], verts[2], verts[3] });
        }
    }

    /// Triangles across one straight edge from `a` to `b`, `inward` being
    /// the unit direction into the rectangle: the fade and the stroke's
    /// band (`band`, distances from the edge with `alphas`), or for a fill
    /// the fade and then solid to `depth`.
    fn edgeBand(out: geometry.Sink, a: Point, b: Point, inward: Point, band: [4]f32, alphas: [4]f32, filled: bool, depth: f32) void {
        const rows: usize = if (filled) 3 else 4;
        var dist: [4]f32 = band;
        var alpha: [4]f32 = alphas;
        if (filled) {
            dist = .{ -0.5, 0.5, depth, 0 };
            alpha = .{ 0, 1, 1, 0 };
            if (depth <= 0.5) return out.quad(at(a, inward, -0.5, 0), at(b, inward, -0.5, 0), at(b, inward, depth, 1), at(a, inward, depth, 1));
        }
        for (0..rows - 1) |i| {
            out.quad(at(a, inward, dist[i], alpha[i]), at(b, inward, dist[i], alpha[i]), at(b, inward, dist[i + 1], alpha[i + 1]), at(a, inward, dist[i + 1], alpha[i + 1]));
        }
    }

    fn at(p: Point, inward: Point, d: f32, alpha: f32) geometry.Vertex {
        return .{ .x = p[0] + inward[0] * d, .y = p[1] + inward[1] * d, .alpha = alpha };
    }

    fn v(x: f32, y: f32, alpha: f32) geometry.Vertex {
        return .{ .x = x, .y = y, .alpha = alpha };
    }

    // --- Recording ----------------------------------------------------------------

    const Op = enum(u8) { rounded_rect, polygon, polyline, text, image };

    /// Notes a shape in the recorder: what it is (its operation, the
    /// fixed-size `params` and the variable `data`, with the clip) and the
    /// area it can touch.
    fn note(c: *Canvas, op: Op, bounds: Rect, params: anytype, data: []const u8) void {
        const rec = c.recorder orelse return;
        var buf: [128]u8 = undefined;
        buf[0] = @backingInt(op);
        var len: usize = 1;
        // Field by field: the tuple's padding is not set.
        inline for (params) |field| {
            const bytes = std.mem.asBytes(&field);
            @memcpy(buf[len..][0..bytes.len], bytes);
            len += bytes.len;
        }
        if (data.len == 0) {
            if (c.clip) |clip| {
                const clip_bytes = std.mem.asBytes(&clip);
                @memcpy(buf[len..][0..clip_bytes.len], clip_bytes);
                len += clip_bytes.len;
            }
            rec.hash.update(buf[0..len]);
        } else {
            rec.hash.update(buf[0..len]);
            rec.hash.update(data);
            if (c.clip) |clip| rec.hash.update(std.mem.asBytes(&clip));
        }
        const area = if (c.clip) |clip| bounds.intersect(clip) orelse return else bounds;
        rec.bounds = if (rec.bounds) |b| b.unite(area) else area;
    }

    // --- Batches ----------------------------------------------------------------

    fn moved(c: *const Canvas, r: Rect) Rect {
        return .{ .x = r.x + c.origin[0], .y = r.y + c.origin[1], .w = r.w, .h = r.h };
    }

    inline fn clipX(c: *const Canvas, x: f32) f32 {
        return x * c.inv_w - 1;
    }

    inline fn clipY(c: *const Canvas, y: f32) f32 {
        return 1 - y * c.inv_h;
    }

    /// How far back `batchFor` looks for a batch to add to.
    const lookback = 32;

    /// The batch a shape of `kind` covering `bounds` goes in: the earliest
    /// of that kind (and clip) among the last few that nothing drawn after
    /// it overlaps (so drawing the shape there changes nothing); otherwise
    /// a new one. The earliest, so that things drawn alike (a grid's
    /// icons, each several shapes over each other) share batches: the
    /// second icon's first shape goes in the first icon's first batch, its
    /// second in the second, and so on.
    fn batchFor(c: *Canvas, kind: Kind, bounds: Rect) ?*Batch {
        return c.batchOf(kind, null, bounds);
    }

    /// The batch an image goes in: like `batchFor`, among those of the
    /// same image.
    fn batchForImage(c: *Canvas, img: *const Image, bounds: Rect) ?*Batch {
        return c.batchOf(.image, img, bounds);
    }

    fn batchOf(c: *Canvas, kind: Kind, image: ?*const Image, bounds: Rect) ?*Batch {
        const items = c.batches.items;
        var found: ?*Batch = null;
        var i = items.len;
        while (i > 0 and items.len - i < lookback) {
            i -= 1;
            const b = &items[i];
            if (b.kind == kind and b.image == image and std.meta.eql(b.clip, c.clip)) found = b;
            if (b.overlaps(bounds)) break;
        }
        if (found) |b| {
            b.cover(c.gpa, bounds);
            return b;
        }
        var b: Batch = if (c.spare.pop()) |s| s else .{ .kind = kind, .bounds = bounds, .clip = null };
        b.kind = kind;
        b.image = image;
        b.bounds = bounds;
        b.clip = c.clip;
        b.areas.clearRetainingCapacity();
        b.areas.append(c.gpa, bounds) catch {};
        c.batches.append(c.gpa, b) catch {
            b.floats.deinit(c.gpa);
            b.areas.deinit(c.gpa);
            c.failed = true;
            return null;
        };
        return &c.batches.items[c.batches.items.len - 1];
    }

    fn append(c: *Canvas, b: *Batch, verts: []const [shaders.shape_floats]f32) void {
        const out = c.vertices(b, shaders.shape_floats, verts.len) orelse return;
        for (verts, out) |v_in, *o| o.* = v_in;
    }

    /// Room for `n` more vertices of `floats` floats at the end of the
    /// batch (written whole, so each is one fixed-size copy).
    fn vertices(c: *Canvas, b: *Batch, comptime floats: usize, n: usize) ?[][floats]f32 {
        const more = b.floats.addManyAsSlice(c.gpa, n * floats) catch {
            c.failed = true;
            return null;
        };
        return @as([*][floats]f32, @ptrCast(more.ptr))[0..n];
    }
};

/// A fingerprint of what was drawn while a canvas's `recorder` pointed at
/// it, and the area it covers (in target pixels, within the clip): two
/// records with the same hash drew the same thing, so a UI can tell what
/// changed between frames, and where, without comparing pixels.
pub const Record = struct {
    hash: std.hash.Wyhash = .init(0),
    bounds: ?Rect = null,

    pub fn final(r: *const Record) u64 {
        var h = r.hash;
        return h.final();
    }
};

/// Turns geometry's triangles into solid vertices of one colour: those
/// opaque all over in an opaque batch (drawn without blending), the rest
/// (anti-aliasing fringes, translucent shapes) in a solid one. The order
/// between them does not matter: blending a colour over itself gives the
/// same colour.
const SolidSink = struct {
    canvas: *Canvas,
    /// The shape's area (for the batches).
    bounds: Rect,
    color: Color,
    /// Added to the triangles' points.
    offset: Point = .{ 0, 0 },
    /// The batches it has added to, by index (adding a batch can move the
    /// others): solid, then opaque.
    batches: [2]?usize = .{ null, null },

    fn sink(s: *SolidSink) geometry.Sink {
        return .{ .ptr = s, .triangle = triangle };
    }

    fn batch(s: *SolidSink, opaque_triangle: bool) ?*Batch {
        const c = s.canvas;
        const slot = &s.batches[@intFromBool(opaque_triangle)];
        if (slot.*) |i| return &c.batches.items[i];
        const b = c.batchFor(if (opaque_triangle) .@"opaque" else .solid, s.bounds) orelse return null;
        slot.* = (@intFromPtr(b) - @intFromPtr(c.batches.items.ptr)) / @sizeOf(Batch);
        return b;
    }

    fn triangle(ptr: *anyopaque, a: geometry.Vertex, b: geometry.Vertex, cc: geometry.Vertex) void {
        const s: *SolidSink = @ptrCast(@alignCast(ptr));
        const c = s.canvas;
        const opaque_triangle = s.color.a >= 1 and a.alpha >= 1 and b.alpha >= 1 and cc.alpha >= 1;
        const target = s.batch(opaque_triangle) orelse return;
        const out = c.vertices(target, shaders.solid_floats, 3) orelse return;
        for ([_]geometry.Vertex{ a, b, cc }, out) |vert, *o| {
            o.* = .{ c.clipX(vert.x + s.offset[0]), c.clipY(vert.y + s.offset[1]), s.color.r, s.color.g, s.color.b, s.color.a * vert.alpha };
        }
    }
};

fn boundsOf(points: []const Point) Rect {
    if (points.len == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var x0 = points[0][0];
    var y0 = points[0][1];
    var x1 = x0;
    var y1 = y0;
    for (points) |p| {
        x0 = @min(x0, p[0]);
        y0 = @min(y0, p[1]);
        x1 = @max(x1, p[0]);
        y1 = @max(y1, p[1]);
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "separate shapes batch together; overlapping ones keep their order" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(200, 100);
    // Three cards side by side: anti-aliased edges, opaque insides and
    // corners, three batches.
    for (0..3) |i| c.fillRoundedRect(.{ .x = 10 + @as(f32, @floatFromInt(i)) * 60, .y = 10, .w = 50, .h = 40 }, .all(8), Color.rgb(0x6750a4));
    try std.testing.expectEqual(@as(usize, 3), c.batches.items.len);
    try std.testing.expectEqual(Kind.solid, c.batches.items[0].kind);
    try std.testing.expectEqual(Kind.@"opaque", c.batches.items[1].kind);
    try std.testing.expectEqual(Kind.shape, c.batches.items[2].kind);
    // Opaque triangles are opaque at every vertex; the fringes are not.
    const o = c.batches.items[1].floats.items;
    var k: usize = 5;
    while (k < o.len) : (k += shaders.solid_floats) try std.testing.expectEqual(@as(f32, 1), o[k]);
    // A card over the first: its batches must follow the first card's.
    c.fillRoundedRect(.{ .x = 20, .y = 20, .w = 30, .h = 20 }, .all(4), Color.rgb(0xffffff));
    try std.testing.expectEqual(@as(usize, 6), c.batches.items.len);
    // Corners: six vertices per corner, four corners per card.
    try std.testing.expectEqual(@as(u32, 3 * 4 * 6), c.batches.items[2].vertexCount());
    // A translucent shape has nothing opaque.
    c.begin(200, 100);
    c.fillRect(.{ .x = 10, .y = 10, .w = 50, .h = 40 }, Color.rgb(0).withAlpha(0.5));
    for (c.batches.items) |b| try std.testing.expect(b.kind != .@"opaque");

    // The origin moves shapes, polygons included.
    c.begin(100, 100);
    c.setOrigin(.{ 50, 0 });
    c.fillPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } }, Color.rgb(0));
    // x = 50 of 100 is clip x 0 (give or take the half-pixel inset).
    try std.testing.expectApproxEqAbs(@as(f32, 0), c.batches.items[0].floats.items[0], 0.03);

    // A circle is four corner cells and nothing else.
    c.begin(100, 100);
    c.fillCircle(.{ 50, 50 }, 20, Color.rgb(0));
    try std.testing.expectEqual(@as(usize, 1), c.batches.items.len);
    try std.testing.expectEqual(Kind.shape, c.batches.items[0].kind);
}

test "things drawn alike share batches, in order" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    // An icon: a translucent-edged card, a smaller one over it, and a mark
    // over that (each over the last, so each layer's batches must come
    // after the one below's).
    const icon = struct {
        fn draw(cv: *Canvas, x: f32, y: f32) void {
            cv.fillRoundedRect(.{ .x = x, .y = y, .w = 40, .h = 40 }, .all(6), Color.rgb(0x6750a4));
            cv.fillRoundedRect(.{ .x = x + 8, .y = y + 8, .w = 24, .h = 24 }, .all(4), Color.rgb(0xffffff));
            cv.fillPolygon(&.{ .{ x + 14, y + 14 }, .{ x + 26, y + 20 }, .{ x + 14, y + 26 } }, Color.rgb(0x00ff00));
        }
    }.draw;
    c.begin(400, 200);
    icon(&c, 10, 10);
    const one = c.batches.items.len;
    // A grid of them: no more batches than one.
    c.begin(400, 200);
    for (0..4) |row| for (0..8) |col| icon(&c, 10 + @as(f32, @floatFromInt(col)) * 48, 10 + @as(f32, @floatFromInt(row)) * 48);
    try std.testing.expectEqual(one, c.batches.items.len);
    // Drawn, every icon shows its layers in order: the mark over the
    // small card over the big one.
    const preview = @import("software.zig");
    const pixels = try std.testing.allocator.alloc(u32, 400 * 200);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xff000000);
    const programs = preview.Programs.load();
    try preview.render(&c, &programs, .{ .pixels = pixels, .width = 400, .height = 200 });
    for (0..4) |row| for (0..8) |col| {
        const x = 10 + col * 48;
        const y = 10 + row * 48;
        try std.testing.expectEqual(@as(u32, 0xff6750a4), pixels[(y + 4) * 400 + x + 20]);
        try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[(y + 30) * 400 + x + 20]);
        try std.testing.expectEqual(@as(u32, 0xff00ff00), pixels[(y + 20) * 400 + x + 18]);
    };
}

test "records tell what was drawn, and where" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    const draw = struct {
        fn f(cv: *Canvas, x: f32, color: Color) Record {
            var rec: Record = .{};
            cv.begin(200, 100);
            cv.recorder = &rec;
            cv.fillRoundedRect(.{ .x = x, .y = 10, .w = 50, .h = 40 }, .all(8), color);
            cv.strokePolyline(&.{ .{ 0, 0 }, .{ 20, 5 } }, false, 2, color);
            return rec;
        }
    }.f;
    const a = draw(&c, 10, Color.rgb(0xff0000));
    const b = draw(&c, 10, Color.rgb(0xff0000));
    try std.testing.expectEqual(a.final(), b.final());
    try std.testing.expect(a.final() != draw(&c, 11, Color.rgb(0xff0000)).final());
    try std.testing.expect(a.final() != draw(&c, 10, Color.rgb(0xfe0000)).final());
    // The rectangle and the line, with a pixel for anti-aliasing.
    const r = a.bounds.?;
    try std.testing.expect(r.x < 0 and r.y < 0 and r.x + r.w >= 61 and r.y + r.h >= 51);
    // A clip limits the area.
    var rec: Record = .{};
    c.begin(200, 100);
    c.recorder = &rec;
    c.setClip(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    c.fillRect(.{ .x = 10, .y = 10, .w = 50, .h = 50 }, Color.rgb(0));
    try std.testing.expectEqual(Rect{ .x = 9, .y = 9, .w = 11, .h = 11 }, rec.bounds.?);
}

test "colour emoji renders multi-coloured layers through the text shader" {
    const preview = @import("software.zig");
    var fira = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const emoji = try font.Font.init(@embedFile("TwemojiMozilla.ttf"));
    fira.fallback = &emoji;

    var atlas = try Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(120, 48);
    _ = c.drawText(&atlas, .{ .font = &fira, .size = 28 }, 4, 34, "😀 ❤️", Color.rgb(0xffffff));

    const pixels = try std.testing.allocator.alloc(u32, 120 * 48);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xff000000);
    const programs = preview.Programs.load();
    try preview.render(&c, &programs, .{ .pixels = pixels, .width = 120, .height = 48 });

    var has_yellow = false;
    var has_red = false;
    for (pixels) |p| {
        const r = (p >> 16) & 0xff;
        const g = (p >> 8) & 0xff;
        const b = p & 0xff;
        if (r > 200 and g > 150 and b < 100) has_yellow = true;
        if (r > 180 and g < 80 and b < 90) has_red = true;
    }
    try std.testing.expect(has_yellow);
    try std.testing.expect(has_red);
}
