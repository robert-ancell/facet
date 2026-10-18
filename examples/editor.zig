//! Multi-line code editor with Zig syntax highlighting (`zig build run-editor`).

const std = @import("std");
const facet = @import("facet");

const sample_code =
    \\// Edit this Zig snippet right in Facet!
    \\const std = @import("std");
    \\
    \\pub fn fibonacci(n: u32) u64 {
    \\    if (n <= 1) return n;
    \\    var a: u64 = 0;
    \\    var b: u64 = 1;
    \\    for (1..n) |_| {
    \\        const next = a + b;
    \\        a = b;
    \\        b = next;
    \\    }
    \\    return b;
    \\}
;

pub fn highlightZig(text: []const u8, out: []facet.Highlight) void {
    const keywords = [_][]const u8{
        "const", "var", "fn", "pub", "return", "if", "else", "for", "while", "struct", "enum",
    };
    const types = [_][]const u8{ "u8", "u16", "u32", "u64", "usize", "i32", "f32", "bool", "void" };

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
            const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            @memset(out[i..end], .comment);
            i = end;
            continue;
        }
        if (text[i] == '"') {
            var end = i + 1;
            while (end < text.len and text[end] != '"') : (end += 1) {
                if (text[end] == '\\' and end + 1 < text.len) end += 1;
            }
            if (end < text.len) end += 1;
            @memset(out[i..end], .string);
            i = end;
            continue;
        }
        if (text[i] == '@') {
            var end = i + 1;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
            @memset(out[i..end], .builtin);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(text[i])) {
            var end = i + 1;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
            @memset(out[i..end], .number);
            i = end;
            continue;
        }
        if (std.ascii.isAlphabetic(text[i]) or text[i] == '_') {
            var end = i + 1;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
            const word = text[i..end];
            for (keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    @memset(out[i..end], .keyword);
                    break;
                }
            } else for (types) |ty| {
                if (std.mem.eql(u8, word, ty)) {
                    @memset(out[i..end], .type);
                    break;
                }
            }
            i = end;
            continue;
        }
        i += 1;
    }
}

pub const EditorView = struct {
    doc: *facet.TextDocument,

    pub fn build(self: *const EditorView, cx: *facet.Context) facet.Widget {
        const t = cx.theme();
        const bytes = self.doc.text();
        const lines = 1 + std.mem.count(u8, bytes, "\n");

        return cx.make(facet.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(facet.TitleBar{ .title = "Syntax-Highlighted TextArea" }),
                cx.make(facet.Expanded{
                    .child = cx.make(facet.Padding{
                        .padding = .all(16),
                        .child = cx.make(facet.Column{
                            .cross_axis_alignment = .stretch,
                            .spacing = 10,
                            .children = &.{
                                cx.make(facet.Expanded{
                                    .child = cx.make(facet.TextArea{
                                        .doc = self.doc,
                                        .autofocus = true,
                                        .highlighter = highlightZig,
                                    }),
                                }),
                                cx.make(facet.Row{
                                    .main_axis_alignment = .space_between,
                                    .children = &.{
                                        cx.make(facet.Text{
                                            .text = cx.fmt("{d} lines · {d} bytes · cursor at {d}", .{
                                                lines,
                                                bytes.len,
                                                self.doc.cursor,
                                            }),
                                            .style = .{ .size = 13, .color = t.on_surface_variant },
                                        }),
                                        cx.make(facet.Text{
                                            .text = "Ctrl+A / Ctrl+C / Ctrl+V or Right-Click for menu",
                                            .style = .{ .size = 13, .color = t.on_surface_variant },
                                        }),
                                    },
                                }),
                            },
                        }),
                    }),
                }),
            },
        });
    }
};

pub fn main(init: std.process.Init) !void {
    var doc = try facet.TextDocument.init(init.gpa, sample_code);
    defer doc.deinit();

    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Facet Editor",
        .size = .{ 720, 520 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), EditorView{ .doc = &doc });
    }
}
