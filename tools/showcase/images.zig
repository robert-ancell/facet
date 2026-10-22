//! Images: pixels in memory, and PNG, JPEG, GIF and WebP files loaded in
//! the background, from bytes or a URL, with what shows while they load
//! and if they cannot be, and parts of them; and QR codes.

const std = @import("std");
const kete = @import("kete");
const common = @import("common.zig");

const picture_size = 96;

/// Pixels made here: a gradient with a ring.
const picture_pixels: [picture_size * picture_size]u32 = blk: {
    @setEvalBranchQuota(100_000);
    var px: [picture_size * picture_size]u32 = undefined;
    for (0..picture_size) |y| for (0..picture_size) |x| {
        const dx = @as(f32, @floatFromInt(x)) - picture_size / 2;
        const dy = @as(f32, @floatFromInt(y)) - picture_size / 2;
        const d2 = dx * dx + dy * dy;
        const r: u32 = x * 255 / (picture_size - 1);
        const g: u32 = y * 255 / (picture_size - 1);
        const b: u32 = if (d2 > 26 * 26 and d2 < 34 * 34) 255 else 160;
        px[y * picture_size + x] = 0xff000000 | (r << 16) | (g << 8) | b;
    };
    break :blk px;
};

/// The same photo (or, for the lossless formats, a drawing) in each format.
const formats = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "JPEG", "Progressive", @embedFile("images/photo.jpg") },
    .{ "JPEG", "Stored on its side, turned upright by its EXIF", @embedFile("images/photo_sideways.jpg") },
    .{ "WebP", "Lossy, with alpha", @embedFile("images/photo.webp") },
    .{ "GIF", "64 colours, interlaced, a transparent circle", @embedFile("images/photo.gif") },
    .{ "PNG", "With alpha", @embedFile("images/graphic.png") },
    .{ "WebP", "Lossless, with alpha", @embedFile("images/graphic.webp") },
};

const default_url = "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/Fronalpstock_big.jpg/500px-Fronalpstock_big.jpg";

pub const State = struct {
    picture: kete.gfx.Image = .{ .pixels = &picture_pixels, .width = picture_size, .height = picture_size, .id = 0x5ca1e },
    /// The URL typed, and the one loaded (`default_url` until one is).
    url_typed: Text = .{},
    url_loaded: Text = .{},
    /// How many times it was loaded again (each a URL of its own, so it is
    /// not the one kept from before).
    reloads: u32 = 0,
    /// The text the QR code encodes, when it has been typed.
    qr: Text = .{},
    /// The part of the photo shown on its own: its top left.
    part_x: f32 = 96,
    part_y: f32 = 40,

    fn setPartX(s: *State, v: f32) void {
        s.part_x = v;
    }
    fn setPartY(s: *State, v: f32) void {
        s.part_y = v;
    }

    fn setQr(s: *State, v: []const u8) void {
        s.qr.set(v);
    }

    fn setUrl(s: *State, v: []const u8) void {
        s.url_typed.set(v);
    }
    fn loadUrl(s: *State) void {
        if (s.url_typed.len > 0) s.url_loaded.set(s.url_typed.buf[0..s.url_typed.len]);
        s.reloads = 0;
    }
    fn reload(s: *State) void {
        s.reloads += 1;
    }
};

const Text = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn set(b: *Text, v: []const u8) void {
        var n = @min(v.len, b.buf.len);
        while (n > 0 and n < v.len and v[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(b.buf[0..n], v[0..n]);
        b.len = n;
    }
};

pub fn build(cx: *kete.BuildContext, s: *State) kete.Widget {
    const t = cx.theme();
    var cards: [formats.len]kete.Widget = undefined;
    for (&cards, formats) |*card, f| {
        card.* = cx.make(kete.Card{
            .variant = .outlined,
            .padding = .all(8),
            .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 6, .children = cx.makeAll(.{
                onChecks(cx, 192, 108, cx.make(kete.Image{ .source = .{ .bytes = f[2] }, .loading = .func(loading), .failed = .func(failed) })),
                kete.Text{ .text = f[0], .style = .{ .size = 14, .color = t.on_surface }, .wrap = false },
                kete.Text{ .text = f[1], .style = .{ .size = 12, .color = t.on_surface_variant } },
            }) }),
        });
    }

    const base = if (s.url_loaded.len > 0) s.url_loaded.buf[0..s.url_loaded.len] else default_url;
    const url = if (s.reloads == 0) base else cx.fmt("{s}{s}again={d}", .{ base, if (std.mem.indexOfScalar(u8, base, '?') != null) "&" else "?", s.reloads });
    const photo = formats[0][2];
    const qr_text = if (s.qr.len > 0) s.qr.buf[0..s.qr.len] else "https://github.com/robert-ancell/kete";
    // The part of the photo on its own: 80 × 60, where the sliders put it.
    const part_size = [2]f32{ 80, 60 };
    const part: kete.Image.Region = .{ .x = @intFromFloat(@round(s.part_x)), .y = @intFromFloat(@round(s.part_y)), .w = 80, .h = 60 };

    return common.page(cx, &.{
        common.section(cx, "Formats", "PNG, JPEG, GIF and WebP, decoded in the background (here from the bytes of files built in)", cx.makeAll(.{
            kete.Grid.fixed(cx, &cards, .{ .w = 210, .h = 200 }, 12),
        })),
        common.section(cx, "From memory", "Pixels the app has made, shown at once: at their size, smaller, and faded", cx.makeAll(.{
            kete.Row{ .spacing = 16, .cross_axis_alignment = .end, .children = cx.makeAll(.{
                kete.SizedBox{ .width = 48, .height = 48, .child = cx.make(kete.Image{ .source = .{ .image = &s.picture } }) },
                kete.SizedBox{ .width = 96, .height = 96, .child = cx.make(kete.Image{ .source = .{ .image = &s.picture } }) },
                kete.SizedBox{ .width = 96, .height = 96, .child = cx.make(kete.Image{ .source = .{ .image = &s.picture }, .opacity = 0.6 }) },
                kete.SizedBox{ .width = 96, .height = 96, .child = cx.make(kete.Image{ .source = .{ .image = &s.picture }, .opacity = 0.25 }) },
            }) },
        })),
        common.section(cx, "Fitting", "Made smaller to fit the space it is given, keeping its shape, but never bigger than it is", cx.makeAll(.{
            kete.Row{ .spacing = 16, .cross_axis_alignment = .start, .children = &.{
                framed(cx, 80, 80, photo),
                framed(cx, 200, 60, photo),
                framed(cx, 90, 140, photo),
            } },
            // Bigger than the photo: it shows at its size.
            framed(cx, 300, 170, photo),
        })),
        common.section(cx, "A part of an image", "Only the part shown is decoded (of a JPEG, only the blocks under it are turned into pixels), so a part of an image too big to load whole can be shown", cx.makeAll(.{
            kete.Row{ .spacing = 16, .cross_axis_alignment = .start, .children = cx.makeAll(.{
                kete.SizedBox{ .width = 256, .height = 144, .child = cx.make(kete.Overlay{ .children = cx.makeAll(.{
                    kete.Image{ .source = .{ .bytes = photo }, .opacity = 0.5 },
                    kete.Align{ .alignment = .top_left, .child = cx.make(kete.Padding{
                        .padding = .{ .left = @round(s.part_x), .top = @round(s.part_y) },
                        .child = cx.make(kete.RoundedBox{
                            .border_width = 2,
                            .border_color = t.primary,
                            .child = cx.make(kete.SizedBox{ .width = part_size[0], .height = part_size[1] }),
                        }),
                    }) },
                }) }) },
                kete.Image{ .source = .{ .bytes = photo }, .region = part, .loading = .func(loading) },
            }) },
            common.labelled(cx, "Across", cx.makeAll(.{
                kete.Expanded{ .child = cx.make(kete.Slider{ .value = s.part_x, .max = 256 - part_size[0], .on_changed = .of(s, State.setPartX) }) },
            })),
            common.labelled(cx, "Down", cx.makeAll(.{
                kete.Expanded{ .child = cx.make(kete.Slider{ .value = s.part_y, .max = 144 - part_size[1], .on_changed = .of(s, State.setPartY) }) },
            })),
            common.status(cx, cx.fmt("The part {d} × {d} from ({d}, {d}): all that is decoded", .{ part.w, part.h, part.x, part.y })),
        })),
        common.section(cx, "From a URL", "Fetched over HTTP or HTTPS (or file:// and data: URLs), with a spinner until it is ready", cx.makeAll(.{
            kete.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = cx.makeAll(.{
                kete.TextField{ .placeholder = "https://…/picture.jpg", .initial = s.url_typed.buf[0..s.url_typed.len], .max_len = 127, .width = 260, .on_changed = .of(s, State.setUrl), .on_submit = .of(s, State.loadUrl) },
                kete.TonalButton{ .label = "Load", .on_press = .of(s, State.loadUrl) },
                kete.TextButton{ .label = "Load again", .icon = .refresh, .on_press = .of(s, State.reload) },
            }) },
            kete.Align{ .alignment = .center_left, .child = onChecks(cx, 300, 170, cx.make(kete.Image{
                .source = .{ .url = url },
                .loading = .func(loading),
                .failed = .func(failed),
            })) },
            common.status(cx, url),
        })),
        common.section(cx, "When it cannot be loaded", "What the failed builder makes shows instead; without one, nothing does", cx.makeAll(.{
            kete.Row{ .spacing = 16, .cross_axis_alignment = .start, .children = &.{
                onChecks(cx, 160, 90, cx.make(kete.Image{ .source = .{ .bytes = "not an image" }, .failed = .func(failed) })),
                onChecks(cx, 160, 90, cx.make(kete.Image{ .source = .{ .file = "/no/such/picture.png" } })),
            } },
        })),
        common.section(cx, "QR code", "Text encoded as a QR code, made as it is typed", cx.makeAll(.{
            kete.Row{ .spacing = 24, .cross_axis_alignment = .center, .children = cx.makeAll(.{
                kete.QrCode{ .text = qr_text, .size = 160 },
                kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 8, .children = cx.makeAll(.{
                    kete.TextField{ .placeholder = "Text to encode", .initial = s.qr.buf[0..s.qr.len], .max_len = 127, .width = 300, .on_changed = .of(s, State.setQr) },
                    kete.Text{ .text = cx.fmt("{d} bytes", .{qr_text.len}), .style = .{ .size = 13, .color = t.on_surface_variant } },
                    kete.QrCode{ .text = "Small", .size = 64 },
                }) },
            }) },
        })),
    });
}

/// `image` centred on a checked background `w` by `h`, so what is
/// transparent in it shows.
fn onChecks(cx: *kete.BuildContext, w: f32, h: f32, image: kete.Widget) kete.Widget {
    return cx.make(kete.SizedBox{ .width = w, .height = h, .child = cx.make(kete.Overlay{ .children = cx.makeAll(.{
        Checks{},
        kete.Align.center(image),
    }) }) });
}

/// The photo in a box `w` by `h`, outlined to show the space it has.
fn framed(cx: *kete.BuildContext, w: f32, h: f32, photo: []const u8) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 4, .children = cx.makeAll(.{
        kete.RoundedBox{ .border_color = t.outline, .child = cx.make(kete.SizedBox{ .width = w, .height = h, .child = cx.make(kete.Align.center(cx.make(kete.Image{ .source = .{ .bytes = photo }, .loading = .func(loading) }))) }) },
        kete.Text{ .text = cx.fmt("{d:.0} × {d:.0}", .{ w, h }), .style = .{ .size = 12, .color = t.on_surface_variant }, .wrap = false },
    }) });
}

fn loading(cx: *kete.BuildContext) kete.Widget {
    return cx.make(kete.Spinner{ .size = 32 });
}

fn failed(cx: *kete.BuildContext) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.Column{ .fill = false, .spacing = 4, .children = cx.makeAll(.{
        kete.Icon{ .icon = .image, .size = 32, .color = t.outline },
        kete.Text{ .text = "Could not be loaded", .style = .{ .size = 12, .color = t.on_surface_variant }, .wrap = false },
    }) });
}

/// A checkerboard, filling its space.
const Checks = struct {
    pub fn layout(_: *const Checks, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return c.biggest();
    }

    pub fn paint(_: *const Checks, n: *kete.WidgetNode, p: *kete.Painter) void {
        const t = p.theme();
        const c = p.canvas();
        const size = 12;
        c.fillRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, t.surface_container);
        var y: f32 = 0;
        var row: usize = 0;
        while (y < n.size.h) : ({
            y += size;
            row += 1;
        }) {
            var x: f32 = if (row % 2 == 0) 0 else size;
            while (x < n.size.w) : (x += 2 * size) {
                c.fillRect(.{ .x = x, .y = y, .w = @min(size, n.size.w - x), .h = @min(size, n.size.h - y) }, t.surface_container_highest);
            }
        }
    }
};
