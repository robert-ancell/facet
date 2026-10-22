//! Image: pixels as big as they are, or made smaller to fit the space
//! given, keeping their shape; never bigger. From pixels in memory, or a
//! PNG, JPEG, GIF or WebP file, URL or file's bytes, loaded in the background (see
//! image_loader.zig): while it loads, and if it cannot be, `loading` and
//! `failed` make what shows instead (a spinner, say), or nothing does.
//!
//!     cx.make(ui.Image{ .source = .{ .image = &photo } })
//!     cx.make(ui.Image{
//!         .source = .{ .url = "https://example.com/cat.jpg" },
//!         .loading = .func(spinner),
//!     })
//!
//! It can show part of an image (`region`): of a file, URL or bytes, only
//! that part is decoded and kept (a JPEG's other blocks are not even
//! turned into pixels), so a part of an image too big to load whole can
//! be shown.
//!
//!     cx.make(ui.Image{ .source = .{ .file = "/photos/panorama.jpg" }, .region = .{ .x = 4000, .y = 1200, .w = 800, .h = 600 } })

const a11y = @import("accessibility.zig");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const loader = @import("image_loader.zig");
const SizedBox = @import("sized_box.zig").SizedBox;

const Node = widget.WidgetNode;
const Context = widget.BuildContext;
const Widget = widget.Widget;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

/// A picture (PNG, JPEG, GIF or WebP), loaded in the background and decoded in
/// pure Zig, or pixels the app has made.
///
/// ![The Image example](images/Image.png)
///
/// ```zig
/// return cx.make(facet.SizedBox{ .width = 160, .height = 100, .child = cx.make(facet.Image{ .source = .{ .image = &photo } }) });
/// ```
pub const Image = struct {
    /// What to show: pixels in memory, a file, a URL, or an image file's bytes.
    source: Source,
    /// The part of it shown, in its pixels (as it is shown: after a
    /// JPEG's EXIF orientation), and as far as it goes; all of it if null.
    region: ?Region = null,
    /// How opaque it is drawn.
    opacity: f32 = 1,
    /// What shows while it loads; nothing if null.
    loading: ?Builder = null,
    /// What shows if it cannot be loaded; nothing if null.
    failed: ?Builder = null,

    pub const Source = loader.Source;
    pub const Region = loader.Region;

    /// Makes what shows in its place (in the frame's arena, with
    /// `cx.make`).
    pub const Builder = struct {
        ctx: *const anyopaque,
        f: *const fn (*const anyopaque, *Context) Widget,

        /// `f(ptr, cx)`: with a pointer, typically to the app's state.
        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context) Widget) Builder {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .f = struct {
                fn call(ctx: *const anyopaque, cx: *Context) Widget {
                    return f(@as(P, @ptrCast(@alignCast(@constCast(ctx)))), cx);
                }
            }.call };
        }

        /// `f(cx)`: needing nothing else.
        pub fn func(comptime f: fn (*Context) Widget) Builder {
            return .{ .ctx = &none, .f = struct {
                fn call(_: *const anyopaque, cx: *Context) Widget {
                    return f(cx);
                }
            }.call };
        }

        const none: u8 = 0;
    };

    pub fn accessible(_: *const Image, _: *Node) ?a11y.Info {
        return .{ .role = .img };
    }

    pub fn build(self: *const Image, cx: *Context) Widget {
        // Pixels in memory: the part of them drawn. Otherwise only the part
        // is loaded.
        if (self.source == .image) {
            const img = self.source.image;
            const part = if (self.region) |r| Region.within(r, img.width, img.height) catch {
                return if (self.failed) |b| b.f(b.ctx, cx) else cx.make(SizedBox.empty);
            } else null;
            return cx.make(Picture{ .image = img, .part = part, .opacity = self.opacity });
        }
        return switch (cx.ui.images.getRegion(self.source, self.region, cx.now())) {
            .ready => |img| cx.make(Picture{ .image = img, .opacity = self.opacity }),
            .loading => if (self.loading) |b| b.f(b.ctx, cx) else cx.make(SizedBox.empty),
            .failed => if (self.failed) |b| b.f(b.ctx, cx) else cx.make(SizedBox.empty),
        };
    }
};

/// The pixels, once there are some (or a part of them).
pub const Picture = struct {
    image: *const gfx.Image,
    /// The part drawn (which must be within it); all of it if null.
    part: ?Image.Region = null,
    opacity: f32 = 1,

    pub fn layout(self: *const Picture, _: *Node, c: Constraints) Size {
        const w: f32 = @floatFromInt(if (self.part) |p| p.w else self.image.width);
        const h: f32 = @floatFromInt(if (self.part) |p| p.h else self.image.height);
        if (w <= 0 or h <= 0) return c.smallest();
        const scale = @min(1, @min(c.max_w / w, c.max_h / h));
        return c.constrain(.{ .w = @round(w * scale), .h = @round(h * scale) });
    }

    pub fn paint(self: *const Picture, n: *Node, p: *Painter) void {
        const part = self.part orelse return p.canvas().drawImage(self.image, .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, self.opacity);
        const iw: f32 = @floatFromInt(self.image.width);
        const ih: f32 = @floatFromInt(self.image.height);
        const s0 = @as(f32, @floatFromInt(part.x)) / iw;
        const t0 = @as(f32, @floatFromInt(part.y)) / ih;
        const s1 = @as(f32, @floatFromInt(part.x1())) / iw;
        const t1 = @as(f32, @floatFromInt(part.y1())) / ih;
        const w = n.size.w;
        const h = n.size.h;
        p.canvas().drawImageTriangles(self.image, &.{
            .{ 0, 0, s0, t0 }, .{ w, 0, s1, t0 }, .{ w, h, s1, t1 },
            .{ 0, 0, s0, t0 }, .{ w, h, s1, t1 }, .{ 0, h, s0, t1 },
        }, self.opacity);
    }
};
