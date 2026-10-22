//! Renders the images on the project's website (`zig build site`): pages of
//! the showcase and two of the example apps, drawn on the CPU in a window-less
//! UI, in the light and the dark theme, as `<name>-light.png` and
//! `<name>-dark.png` in the directory named on the command line.

const std = @import("std");
const kete = @import("kete");
const showcase = @import("showcase");
const navigation = @import("navigation");
const editor = @import("editor");

/// How many pixels each logical pixel is drawn with.
const scale = 2;

const sample_notes = "Kete: a declarative UI toolkit for Zig.";

const sample_code =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    std.debug.print("Hello, Kete!\n", .{});
    \\}
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDirectory;
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out.close(io);

    var notes = try kete.TextDocument.init(gpa, sample_notes);
    defer notes.deinit();
    var code = try kete.TextDocument.init(gpa, sample_code);
    defer code.deinit();
    var doc = try kete.TextDocument.init(gpa, editor_code);
    defer doc.deinit();

    for ([_]kete.Theme{ .light, .dark }, [_][]const u8{ "light", "dark" }) |theme, theme_name| {
        const Env = struct { gpa: std.mem.Allocator, io: std.Io, out: std.Io.Dir, theme: kete.Theme, theme_name: []const u8 };
        const env: Env = .{ .gpa = gpa, .io = io, .out = out, .theme = theme, .theme_name = theme_name };

        const tour: showcase.Showcase = .{ .notes = &notes, .code = &code };
        try render(env, "selection", tour, 1000, 660, .selection);
        try render(env, "maps", tour, 1000, 660, .maps);
        try render(env, "navigation", navigation.NavigationDemo{}, 800, 520, null);
        try render(env, "editor", editor.EditorView{ .doc = &doc }, 720, 520, null);
    }
}

const editor_code =
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

/// Draws `root` in a `w` by `h` window (on `page`, if it is the showcase) and
/// writes it as `<name>-<theme>.png`.
fn render(env: anytype, comptime name: []const u8, root: anytype, w: u32, h: u32, page: ?showcase.Page) !void {
    const u = try kete.ui.WindowUi.createDefault(env.gpa, env.io);
    defer u.destroy();
    u.theme = env.theme;
    u.scale = scale;
    // A few frames: the first makes it, later ones let what loads (and what
    // is drawn in its own time) settle.
    var now: u64 = 0;
    for (0..4) |i| {
        u.frame(w, h, now, root);
        if (i == 0) if (page) |p| {
            u.root.?.state(showcase.Showcase.State).page = p;
        };
        now += 100 * std.time.ns_per_ms;
    }
    const pixels = try env.gpa.alloc(u32, w * scale * h * scale);
    defer env.gpa.free(pixels);
    @memset(pixels, u.theme.surface.toArgb());
    try u.preview(.{ .pixels = pixels, .width = w * scale, .height = h * scale });
    const png = try kete.gfx.png.encode(env.gpa, pixels, w * scale, h * scale);
    defer env.gpa.free(png);
    const path = try std.fmt.allocPrint(env.gpa, "{s}-{s}.png", .{ name, env.theme_name });
    defer env.gpa.free(path);
    var f = try env.out.createFile(env.io, path, .{});
    defer f.close(env.io);
    try f.writeStreamingAll(env.io, png);
}
