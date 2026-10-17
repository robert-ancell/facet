//! Generic 2D rendering interface (`Renderer`), viewport and scissor types,
//! and custom GPU draw segments (`GpuArea`, `GpuDraw`, `Segment`).
//!
//! Built-in rendering backends:
//! * `software.SoftwareRenderer` (`gfx.software`)
//! * `opengl.OpenGlRenderer` (`gfx.opengl`)
//! * `vulkan.VulkanRenderer` (`gfx.vulkan`)
//!
//! Any custom backend (e.g., Metal, Direct3D, or WebGPU) can
//! implement `prepare`, `record`, and optional `deinit` and wrap itself via
//! `Renderer.of(&my_backend)`.

const std = @import("std");
const canvas_mod = @import("canvas.zig");

pub const Canvas = canvas_mod.Canvas;
pub const Rect = canvas_mod.Rect;

/// A rectangle in whole target pixels.
pub const Viewport = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn intersects(a: Viewport, b: Viewport) bool {
        const ax1 = a.x + @as(i32, @intCast(a.width));
        const ay1 = a.y + @as(i32, @intCast(a.height));
        const bx1 = b.x + @as(i32, @intCast(b.width));
        const by1 = b.y + @as(i32, @intCast(b.height));
        return a.x < bx1 and b.x < ax1 and a.y < by1 and b.y < ay1;
    }

    pub fn intersect(a: Viewport, b: Viewport) ?Viewport {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + @as(i32, @intCast(a.width)), b.x + @as(i32, @intCast(b.width)));
        const y1 = @min(a.y + @as(i32, @intCast(a.height)), b.y + @as(i32, @intCast(b.height)));
        if (x1 <= x0 or y1 <= y0) return null;
        return .{
            .x = x0,
            .y = y0,
            .width = @intCast(x1 - x0),
            .height = @intCast(y1 - y0),
        };
    }
};

/// Where a custom GPU draw goes, in the frame's pixels.
pub const GpuArea = struct {
    /// The widget's box (draw with it as the viewport).
    viewport: Viewport,
    /// The part of it that may be drawn on (null if all of it).
    scissor: ?Viewport = null,
};

/// A custom draw callback recorded in tree order between 2D canvas segments.
/// `target` is the opaque frame/command-buffer pointer passed to `Renderer.renderSegments`.
pub const GpuDraw = struct {
    ctx: *const anyopaque,
    f: *const fn (ctx: *const anyopaque, target: *anyopaque, area: GpuArea) anyerror!void,
    area: GpuArea,
};

/// One layer of a painted frame: either a 2D `Canvas` or a custom `GpuDraw`.
pub const Segment = union(enum) {
    canvas: *Canvas,
    gpu: GpuDraw,
};

/// Converts a floating-point clip rectangle into a pixel `Viewport` scissor.
pub fn scissor(clip: Rect) Viewport {
    const x0 = @floor(@max(clip.x, 0));
    const y0 = @floor(@max(clip.y, 0));
    const x1 = @max(@ceil(clip.x + clip.w), x0);
    const y1 = @max(@ceil(clip.y + clip.h), y0);
    return .{
        .x = @intFromFloat(@min(x0, 1e6)),
        .y = @intFromFloat(@min(y0, 1e6)),
        .width = @intFromFloat(@min(x1 - x0, 1e6)),
        .height = @intFromFloat(@min(y1 - y0, 1e6)),
    };
}

/// Checks whether `vp` overlaps any viewport in `damage` (or returns `true`
/// when `damage` is `null`, meaning the entire frame is being drawn).
pub fn covers(damage: ?[]const Viewport, vp: Viewport) bool {
    const list = damage orelse return true;
    for (list) |d| {
        if (d.intersects(vp)) return true;
    }
    return false;
}

/// Type-erased rendering backend interface.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Uploads vertex batches, dirty glyph atlas rows, and image textures
        /// for all canvases in the frame.
        prepare: *const fn (ptr: *anyopaque, canvases: []const *const Canvas) anyerror!void,
        /// Draws a prepared canvas into `target`, optionally clipped to `damage`
        /// regions.
        record: *const fn (ptr: *anyopaque, canvas: *const Canvas, target: *anyopaque, damage: ?[]const Viewport) anyerror!void,
        /// Releases backend resources, if any.
        deinit: ?*const fn (ptr: *anyopaque) void = null,
    };

    /// Wraps any backend pointer `*T` that implements:
    /// * `pub fn prepare(self: *T, canvases: []const *const Canvas) !void`
    /// * `pub fn record(self: *T, canvas: *const Canvas, target: *Target, damage: ?[]const Viewport) !void`
    /// * (optional) `pub fn deinit(self: *T) void`
    pub fn of(impl: anytype) Renderer {
        const Ptr = @TypeOf(impl);
        const T = @typeInfo(Ptr).pointer.child;
        return .{
            .ptr = impl,
            .vtable = &struct {
                const vtable: VTable = .{
                    .prepare = prepareFn,
                    .record = recordFn,
                    .deinit = if (@hasDecl(T, "deinit")) deinitFn else null,
                };
                fn prepareFn(ptr: *anyopaque, canvases: []const *const Canvas) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    return self.prepare(canvases);
                }
                fn recordFn(ptr: *anyopaque, c: *const Canvas, target: *anyopaque, damage: ?[]const Viewport) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    return self.record(c, @ptrCast(@alignCast(target)), damage);
                }
                fn deinitFn(ptr: *anyopaque) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.deinit();
                }
            }.vtable,
        };
    }

    pub fn prepare(r: Renderer, canvases: []const *const Canvas) !void {
        return r.vtable.prepare(r.ptr, canvases);
    }

    pub fn record(r: Renderer, c: *const Canvas, target: anytype, damage: ?[]const Viewport) !void {
        return r.vtable.record(r.ptr, c, @ptrCast(@constCast(target)), damage);
    }

    /// Draws a single canvas in one step.
    pub fn draw(r: Renderer, c: *const Canvas, target: anytype) !void {
        try r.prepare(&.{c});
        try r.record(c, target, null);
    }

    /// Renders all segments (`Canvas` and custom `GpuDraw`) into `target`.
    pub fn render(
        r: Renderer,
        segments: []const Segment,
        target: *anyopaque,
        _: u32,
        _: u32,
        damage: ?[]const Viewport,
    ) !void {
        for (segments) |s| switch (s) {
            .canvas => |c| try r.vtable.record(r.ptr, c, target, damage),
            .gpu => |g| {
                const active_vp = g.area.scissor orelse g.area.viewport;
                if (covers(damage, active_vp)) {
                    try g.f(g.ctx, target, g.area);
                }
            },
        };
    }

    /// Prepares all canvas segments and records both canvas segments and
    /// custom `GpuDraw` segments in order.
    pub fn renderSegments(
        r: Renderer,
        canvases: []const *const Canvas,
        segments: []const Segment,
        target: anytype,
        damage: ?[]const Viewport,
    ) !void {
        try r.prepare(canvases);
        const target_ptr: *anyopaque = @ptrCast(@constCast(target));
        try r.render(segments, target_ptr, 0, 0, damage);
    }

    pub fn deinit(r: Renderer) void {
        if (r.vtable.deinit) |f| f(r.ptr);
    }
};
