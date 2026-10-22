//! Multi-line code editor with Zig syntax highlighting (`zig build run-editor`).

const std = @import("std");
const kete = @import("kete");

const sample_code =
    \\// Edit this Zig snippet right in Kete!
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

pub fn highlightZig(text: []const u8, out: []kete.SyntaxHighlight) void {
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
    doc: *kete.TextDocument,

    pub fn build(self: *const EditorView, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const bytes = self.doc.text();
        const lines = 1 + std.mem.count(u8, bytes, "\n");

        return cx.make(kete.Padding{
            .padding = .all(16),
            .child = cx.make(kete.Column{
                .cross_axis_alignment = .stretch,
                .spacing = 10,
                .children = cx.makeAll(.{
                    kete.Expanded{
                        .child = cx.make(kete.TextArea{
                            .doc = self.doc,
                            .autofocus = true,
                            .highlighter = highlightZig,
                        }),
                    },
                    kete.Row{
                        .main_axis_alignment = .space_between,
                        .children = cx.makeAll(.{
                            kete.Text{
                                .text = cx.fmt("{d} lines · {d} bytes · cursor at {d}", .{
                                    lines,
                                    bytes.len,
                                    self.doc.cursor,
                                }),
                                .style = .{ .size = 13, .color = t.on_surface_variant },
                            },
                            kete.Text{
                                .text = "Ctrl+A / Ctrl+C / Ctrl+V or Right-Click for menu",
                                .style = .{ .size = 13, .color = t.on_surface_variant },
                            },
                        }),
                    },
                }),
            }),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    var doc = try kete.TextDocument.init(init.gpa, sample_code);
    defer doc.deinit();

    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root = EditorView{ .doc = &doc };
    _ = try app.openWindow(.{
        .title = "Kete Editor",
        .root = .of(&root),
        .size = .{ 720, 520 },
        .on_close_request = .close,
    });
    try app.run();
}
