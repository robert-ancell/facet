//! Renders the images in the API reference (`zig build docs`): one per
//! widget, from the example in `docs_examples.zig`, drawn on the CPU in a
//! window-less UI and written as `<Widget>.png` to the directory named on
//! the command line.

const std = @import("std");
const facet = @import("facet");
const examples = @import("docs_examples.zig");

/// The space around each example, in logical pixels.
const margin = 16;
/// The widest an example is let be, in logical pixels.
const max_width = 480;
/// How many pixels each logical pixel is drawn with.
const scale = 2;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDirectory;

    var out = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out.close(io);

    const u = try facet.WindowUi.createDefault(gpa, io);
    defer u.destroy();
    u.theme = facet.Theme.light;
    u.scale = scale;
    try examples.init(gpa);
    defer examples.deinit(gpa);

    var frame: u64 = 0;
    inline for (examples.all) |ex| {
        const Root = ex.Root;
        // Its size: the one given, or what it takes with room to spare.
        var w: u32 = ex.width orelse 0;
        var h: u32 = ex.height orelse 0;
        if (w == 0 or h == 0) {
            frame += 1;
            u.frame(max_width, 800, frame, Root{ .measure = true });
            const size = u.root.?.child(0).child(0).size;
            w = @intFromFloat(@ceil(size.w));
            h = @intFromFloat(@ceil(size.h));
        }
        frame += 1;
        u.frame(w, h, frame, Root{});
        if (ex.after) |after| {
            after(u);
            frame += 1;
            u.frame(w, h, frame, Root{});
        }
        const pixels = try gpa.alloc(u32, w * scale * h * scale);
        defer gpa.free(pixels);
        @memset(pixels, u.theme.surface.toArgb());
        try u.preview(.{ .pixels = pixels, .width = w * scale, .height = h * scale });
        const png = try facet.gfx.png.encode(gpa, pixels, w * scale, h * scale);
        defer gpa.free(png);
        var file = try out.createFile(io, ex.name ++ ".png", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, png);
    }
}
