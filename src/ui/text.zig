//! Text: lines broken at `\n`, and wrapped at spaces to fit the width. A
//! word wider than the space it has overflows (and is marked).

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Node = widget.Node;
const Painter = painter_mod.Painter;

pub const TextStyle = struct {
    /// Pixels per em (the theme's body size if not given).
    size: ?f32 = null,
    /// The theme's text colour if not given.
    color: ?gfx.Color = null,
    /// The UI's font if not given (another must last as long as the text
    /// is shown).
    font: ?*const font.Font = null,
};

pub const TextAlign = enum { start, center, end };

pub const Line = struct {
    text: []const u8,
    width: f32,
};

pub const Text = struct {
    text: []const u8,
    style: TextStyle = .{},
    text_align: TextAlign = .start,
    /// Wrap at spaces to fit the width (otherwise only `\n` breaks lines).
    wrap: bool = true,
    /// End lines too wide for the space with "…" instead of overflowing.
    ellipsis: bool = false,

    const Laid = struct { lines: []const Line, style: font.Style };

    fn fontStyle(self: *const Text, n: *const Node) ?font.Style {
        const f = self.style.font orelse n.ui.font orelse return null;
        const size = self.style.size orelse n.ui.theme.body_size;
        if (!(size > 0) or !std.math.isFinite(size)) return null;
        return .{ .font = f, .size = size };
    }

    pub fn layout(self: *const Text, n: *Node, c: Constraints) Size {
        const style = self.fontStyle(n) orelse return c.smallest();
        const arena = n.ui.arena();
        const lines = wrap(arena, &n.ui.atlas.runs, style, self.text, if (self.wrap) c.max_w else geometry.inf) catch return c.smallest();
        if (self.ellipsis and c.boundedWidth()) for (lines) |*l| {
            if (l.width > c.max_w) l.* = ellipsize(arena, &n.ui.atlas.runs, style, l.text, c.max_w) catch l.*;
        };
        var widest: f32 = 0;
        for (lines) |l| widest = @max(widest, l.width);
        const height = @as(f32, @floatFromInt(lines.len)) * style.lineHeight();
        const laid = arena.create(Laid) catch return c.smallest();
        laid.* = .{ .lines = lines, .style = style };
        n.scratch = laid;
        n.setContent(.{ .x = 0, .y = 0, .w = widest, .h = height });
        return c.constrain(.{ .w = @ceil(widest), .h = @ceil(height) });
    }

    pub fn minSize(self: *const Text, n: *Node, c: Constraints) Size {
        const style = self.fontStyle(n) orelse return c.smallest();
        const arena = n.ui.arena();
        const lines = wrap(arena, &n.ui.atlas.runs, style, self.text, if (self.wrap) c.max_w else geometry.inf) catch return c.smallest();
        var widest: f32 = 0;
        if (self.ellipsis) {
            widest = if (self.text.len > 0) n.ui.atlas.runs.measure(style, ellipsis_text) else 0;
        } else {
            for (lines) |l| widest = @max(widest, l.width);
        }
        const height = @as(f32, @floatFromInt(lines.len)) * style.lineHeight();
        return c.constrain(.{ .w = @ceil(widest), .h = @ceil(height) });
    }

    pub fn paint(self: *const Text, n: *Node, p: *Painter) void {
        const laid: *const Laid = @ptrCast(@alignCast(n.scratch orelse return));
        const color = self.style.color orelse n.ui.theme.on_surface;
        const lh = laid.style.lineHeight();
        for (laid.lines, 0..) |l, i| {
            const x = switch (self.text_align) {
                .start => 0,
                .center => @max((n.size.w - l.width) / 2, 0),
                .end => @max(n.size.w - l.width, 0),
            };
            const baseline = @as(f32, @floatFromInt(i)) * lh + laid.style.ascent();
            _ = p.text(laid.style.size, x, baseline, l.text, color);
        }
    }
};

const ellipsis_text = "…";

/// As much of `text` as fits `max_width` with "…" after it.
pub fn ellipsize(gpa: std.mem.Allocator, runs: *font.RunCache, style: font.Style, text: []const u8, max_width: f32) !Line {
    const dots = runs.measure(style, ellipsis_text);
    if (dots > max_width) return .{ .text = "", .width = 0 };
    var l = font.Layout.init(style, text, 0);
    var end: usize = 0;
    while (l.next()) |_| {
        if (l.x + dots > max_width) break;
        end = l.at;
    }
    const kept = std.mem.trimEnd(u8, text[0..end], " ");
    const out = try std.mem.concat(gpa, u8, &.{ kept, ellipsis_text });
    return .{ .text = out, .width = runs.measure(style, out) };
}

/// Breaks text into lines no wider than `max_width` where it can: at
/// newlines, and at spaces (a word too wide gets a line of its own).
pub fn wrap(gpa: std.mem.Allocator, runs: *font.RunCache, style: font.Style, text: []const u8, max_width: f32) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |para| {
        const whole = runs.measure(style, para);
        if (whole <= max_width) {
            try lines.append(gpa, .{ .text = para, .width = whole });
            continue;
        }
        var start: usize = 0;
        while (start < para.len) {
            // The longest run of whole words that fits, or one word.
            var end = std.mem.indexOfScalarPos(u8, para, start, ' ') orelse para.len;
            var width: f32 = 0;
            var target_rel: usize = end - start;
            var have_first = false;
            var l = font.Layout.init(style, para[start..], 0);
            while (l.next()) |_| {
                if (l.at == target_rel) {
                    if (!have_first) {
                        have_first = true;
                        width = l.x;
                        if (end >= para.len or width > max_width) break;
                        const next = std.mem.indexOfScalarPos(u8, para, end + 1, ' ') orelse para.len;
                        target_rel = next - start;
                    } else {
                        if (l.x > max_width) break;
                        end = start + target_rel;
                        width = l.x;
                        if (end >= para.len) break;
                        const next = std.mem.indexOfScalarPos(u8, para, end + 1, ' ') orelse para.len;
                        target_rel = next - start;
                    }
                }
            }
            try lines.append(gpa, .{ .text = para[start..end], .width = width });
            // The spaces where it broke start no line.
            start = end;
            while (start < para.len and para[start] == ' ') start += 1;
        }
    }
    return lines.items;
}

test "ellipsis" {
    const f = try font.Font.init(font.default_font_data);
    const style: font.Style = .{ .font = &f, .size = 16 };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var runs = font.RunCache.init(gpa);
    defer runs.deinit();
    const name = "archive-2026-10-18-backup-snapshot.tar.gz";
    const max = font.measure(style, "archive-2026…");
    const l = try ellipsize(arena.allocator(), &runs, style, name, max);
    try std.testing.expectEqualStrings("archive-2026…", l.text);
    try std.testing.expect(l.width <= max);
    // Characters are not split.
    const accents = try ellipsize(arena.allocator(), &runs, style, "éééééééééé", font.measure(style, "éé…") + 1);
    try std.testing.expectEqualStrings("éé…", accents.text);
    // Too narrow for even the dots: nothing.
    try std.testing.expectEqualStrings("", (try ellipsize(arena.allocator(), &runs, style, name, 2)).text);
}

test "wrapping" {
    const f = try font.Font.init(font.default_font_data);
    const style: font.Style = .{ .font = &f, .size = 16 };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var runs = font.RunCache.init(gpa);
    defer runs.deinit();
    const one = try wrap(a, &runs, style, "Hello there", geometry.inf);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    const w = font.measure(style, "Hello there");
    const two = try wrap(a, &runs, style, "Hello there world", w + 1);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("Hello there", two[0].text);
    try std.testing.expectEqualStrings("world", two[1].text);
    // A word wider than the space still gets a line, and breaks show.
    const long = try wrap(a, &runs, style, "Supercalifragilistic is\nlong", 30);
    try std.testing.expectEqualStrings("Supercalifragilistic", long[0].text);
    try std.testing.expect(long[0].width > 30);
    try std.testing.expectEqualStrings("is", long[1].text);
    try std.testing.expectEqualStrings("long", long[2].text);
}
