//! Text: text in different sizes, colours and alignments, single-line text
//! fields, and multi-line text areas, plain and with code highlighted.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

pub const initial_notes =
    \\Edit this text: select it with the mouse or with Shift and the arrow keys,
    \\and cut, copy and paste with the keyboard or the right-click menu.
;

pub const initial_code =
    \\// Code is highlighted as it is typed.
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    const answer: u32 = 6 * 7;
    \\    std.debug.print("The answer is {d}\n", .{answer});
    \\}
;

const lorem = "Facet lays text out with its own font engine: it is shaped, wrapped at word boundaries to fit the space it is given, and drawn with subpixel positioning.";

pub const State = struct {
    name: Buffer = .{},
    password: Buffer = .{},
    search: Buffer = .{},
    submitted: common.Log = .{},

    fn setName(s: *State, v: []const u8) void {
        s.name.set(v);
    }
    fn setPassword(s: *State, v: []const u8) void {
        s.password.set(v);
    }
    fn setSearch(s: *State, v: []const u8) void {
        s.search.set(v);
    }
    fn submitSearch(s: *State) void {
        s.submitted.set("Searched for “{s}”", .{s.search.text()});
    }
};

/// A text field's text.
const Buffer = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn set(b: *Buffer, v: []const u8) void {
        var n = @min(v.len, b.buf.len);
        while (n > 0 and n < v.len and v[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(b.buf[0..n], v[0..n]);
        b.len = n;
    }

    fn text(b: *const Buffer) []const u8 {
        return b.buf[0..b.len];
    }
};

pub fn build(cx: *facet.Context, s: *State, notes: *facet.TextDocument, code: *facet.TextDocument) facet.Widget {
    const t = cx.theme();
    return common.page(cx, &.{
        common.section(cx, "Text", "Text in the theme's sizes and colours", &.{
            cx.make(facet.Text{ .text = "Title text", .style = .{ .size = t.title_size, .color = t.on_surface } }),
            cx.make(facet.Text{ .text = "Body text, the size most text is", .style = .{ .size = t.body_size, .color = t.on_surface } }),
            cx.make(facet.Text{ .text = "Supporting text, quieter than the body", .style = .{ .size = 13, .color = t.on_surface_variant } }),
            cx.make(facet.Text{ .text = "Primary colour for emphasis", .style = .{ .size = t.body_size, .color = t.primary } }),
            cx.make(facet.Text{ .text = "Error colour for problems", .style = .{ .size = t.body_size, .color = t.@"error" } }),
            cx.make(facet.Text{ .text = "Accents and emoji: Grüße, café, naïve 🎉", .style = .{ .size = t.body_size, .color = t.on_surface } }),
        }),
        common.section(cx, "Layout", "Text wrapped to its width, cut short with an ellipsis, and aligned", &.{
            common.labelled(cx, "Wrapped", &.{cx.make(facet.Expanded{ .child = cx.make(facet.Text{ .text = lorem, .style = .{ .color = t.on_surface } }) })}),
            common.labelled(cx, "Ellipsis", &.{cx.make(facet.Expanded{ .child = cx.make(facet.Text{ .text = lorem, .wrap = false, .ellipsis = true, .style = .{ .color = t.on_surface } }) })}),
            common.labelled(cx, "Start", &.{aligned(cx, .start)}),
            common.labelled(cx, "Center", &.{aligned(cx, .center)}),
            common.labelled(cx, "End", &.{aligned(cx, .end)}),
        }),
        common.section(cx, "Text fields", "Single lines of text: typed, hidden, submitted with Enter, or unavailable", &.{
            common.labelled(cx, "Name", &.{
                cx.make(facet.TextField{ .placeholder = "Your name", .initial = s.name.text(), .on_changed = .of(s, State.setName) }),
                cx.make(facet.Text{
                    .text = if (s.name.len == 0) "" else cx.fmt("Hello, {s}!", .{s.name.text()}),
                    .style = .{ .size = 13, .color = t.primary },
                    .wrap = false,
                    .ellipsis = true,
                }),
            }),
            common.labelled(cx, "Password", &.{
                cx.make(facet.TextField{ .placeholder = "Password", .obscure = true, .initial = s.password.text(), .on_changed = .of(s, State.setPassword) }),
                cx.make(facet.Text{ .text = cx.fmt("{d} characters", .{std.unicode.utf8CountCodepoints(s.password.text()) catch 0}), .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false }),
            }),
            common.labelled(cx, "Search", &.{
                cx.make(facet.TextField{ .placeholder = "Type and press Enter", .initial = s.search.text(), .on_changed = .of(s, State.setSearch), .on_submit = .of(s, State.submitSearch) }),
                common.status(cx, s.submitted.text("")),
            }),
            common.labelled(cx, "Large", &.{
                cx.make(facet.TextField{ .placeholder = "Larger text", .size = 20, .width = 320 }),
            }),
            common.labelled(cx, "Disabled", &.{
                cx.make(facet.TextField{ .initial = "Can't be edited", .enabled = false }),
            }),
        }),
        common.section(cx, "Text areas", "Many lines of text in a shared document, plain or with code highlighted", &.{
            area(cx, notes, null, 96),
            area(cx, code, highlightZig, 160),
            cx.make(facet.Text{
                .text = cx.fmt("The code is {d} lines, {d} bytes, with the cursor at {d}", .{ 1 + std.mem.count(u8, code.text(), "\n"), code.text().len, code.cursor }),
                .style = .{ .size = 13, .color = t.on_surface_variant },
            }),
        }),
    });
}

fn aligned(cx: *facet.Context, a: facet.TextAlign) facet.Widget {
    const t = cx.theme();
    return cx.make(facet.Expanded{ .child = cx.make(facet.Decorated{
        .color = t.surface_container,
        .radius = .all(6),
        .child = cx.make(facet.Padding{
            .padding = .symmetric(10, 6),
            .child = cx.make(facet.Text{ .text = cx.fmt("Aligned to the {s}", .{@tagName(a)}), .text_align = a, .style = .{ .color = t.on_surface } }),
        }),
    }) });
}

fn area(cx: *facet.Context, doc: *facet.TextDocument, highlighter: ?facet.TextArea.Highlighter, height: f32) facet.Widget {
    const t = cx.theme();
    return cx.make(facet.SizedBox{
        .height = height,
        .child = cx.make(facet.Decorated{
            .color = t.surface_container,
            .border = .{ .width = 1, .color = t.outline_variant },
            .radius = .all(8),
            .child = cx.make(facet.TextArea{ .doc = doc, .highlighter = highlighter }),
        }),
    });
}

/// Colours a little of Zig: comments, strings, builtins, numbers, keywords
/// and types.
fn highlightZig(text: []const u8, out: []facet.Highlight) void {
    const keywords = [_][]const u8{ "const", "var", "fn", "pub", "return", "if", "else", "for", "while", "struct", "enum" };
    const types = [_][]const u8{ "u8", "u16", "u32", "u64", "usize", "i32", "f32", "bool", "void" };
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const kind: facet.Highlight = if (std.mem.startsWith(u8, text[i..], "//")) blk: {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            break :blk .comment;
        } else if (text[i] == '"') blk: {
            i += 1;
            while (i < text.len and text[i] != '"' and text[i] != '\n') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            i = @min(i + 1, text.len);
            break :blk .string;
        } else if (text[i] == '@' or std.ascii.isAlphanumeric(text[i]) or text[i] == '_') blk: {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
            const word = text[start..i];
            if (word[0] == '@') break :blk .builtin;
            if (std.ascii.isDigit(word[0])) break :blk .number;
            for (keywords) |kw| if (std.mem.eql(u8, word, kw)) break :blk .keyword;
            for (types) |ty| if (std.mem.eql(u8, word, ty)) break :blk .type;
            break :blk .plain;
        } else blk: {
            i += 1;
            break :blk .plain;
        };
        @memset(out[start..i], kind);
    }
}
