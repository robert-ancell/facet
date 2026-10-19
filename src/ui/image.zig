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

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const loader = @import("image_loader.zig");
const Empty = @import("empty.zig").Empty;

const Node = widget.Node;
const Context = widget.Context;
const Widget = widget.Widget;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const Image = struct {
    source: Source,
    /// How opaque it is drawn.
    opacity: f32 = 1,
    /// What shows while it loads; nothing if null.
    loading: ?Builder = null,
    /// What shows if it cannot be loaded; nothing if null.
    failed: ?Builder = null,

    pub const Source = loader.Source;

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

    pub fn build(self: *const Image, cx: *Context) Widget {
        return switch (cx.ui.images.get(self.source, cx.now())) {
            .ready => |img| cx.make(Picture{ .image = img, .opacity = self.opacity }),
            .loading => if (self.loading) |b| b.f(b.ctx, cx) else cx.make(Empty{}),
            .failed => if (self.failed) |b| b.f(b.ctx, cx) else cx.make(Empty{}),
        };
    }
};

/// The pixels, once there are some.
pub const Picture = struct {
    image: *const gfx.Image,
    opacity: f32 = 1,

    pub fn layout(self: *const Picture, _: *Node, c: Constraints) Size {
        const w: f32 = @floatFromInt(self.image.width);
        const h: f32 = @floatFromInt(self.image.height);
        if (w <= 0 or h <= 0) return c.smallest();
        const scale = @min(1, @min(c.max_w / w, c.max_h / h));
        return c.constrain(.{ .w = @round(w * scale), .h = @round(h * scale) });
    }

    pub fn paint(self: *const Picture, n: *Node, p: *Painter) void {
        p.canvas().drawImage(self.image, .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, self.opacity);
    }
};
