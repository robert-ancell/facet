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
/// `target` is the frame/command-buffer pointer passed to `Renderer.render`.
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

/// Identifies the 2D rendering backend implementation.
pub const RenderBackend = enum {
    software,
    opengl,
    vulkan,
    custom,

    pub fn name(b: RenderBackend) []const u8 {
        return switch (b) {
            .software => "Software",
            .opengl => "OpenGL",
            .vulkan => "Vulkan",
            .custom => "Custom",
        };
    }
};

/// Identifies a type at run time (one address per type).
pub const TypeId = *const anyopaque;

pub fn typeId(comptime T: type) TypeId {
    return &struct {
        const Type = T;
        var byte: u8 = 0;
    }.byte;
}

/// Type-erased rendering backend interface.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        backend: RenderBackend = .custom,
        /// The type `record`'s target points to (see `typeId`).
        target: TypeId,
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
    ///   (or `*const Target`)
    /// * (optional) `pub fn deinit(self: *T) void`
    ///
    /// Drawing into a pointer to anything but a `Target` is `error.WrongTarget`.
    pub fn of(impl: anytype) Renderer {
        const Ptr = @TypeOf(impl);
        const T = @typeInfo(Ptr).pointer.child;
        const Target = @typeInfo(@typeInfo(@TypeOf(T.record)).@"fn".param_types[2].?).pointer.child;
        return .{
            .ptr = impl,
            .vtable = &struct {
                const vtable: VTable = .{
                    .backend = if (@hasDecl(T, "backend")) T.backend else .custom,
                    .target = typeId(Target),
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

    pub fn backend(r: Renderer) RenderBackend {
        return r.vtable.backend;
    }

    pub fn prepare(r: Renderer, canvases: []const *const Canvas) !void {
        return r.vtable.prepare(r.ptr, canvases);
    }

    /// `target` as the backend gets it, if it points to the backend's
    /// target type.
    fn targetPtr(r: Renderer, target: anytype) !*anyopaque {
        const info = @typeInfo(@TypeOf(target));
        if (info != .pointer or info.pointer.size != .one) @compileError("the render target must be a pointer, not " ++ @typeName(@TypeOf(target)));
        if (typeId(info.pointer.child) != r.vtable.target) return error.WrongTarget;
        return @ptrCast(@constCast(target));
    }

    pub fn record(r: Renderer, c: *const Canvas, target: anytype, damage: ?[]const Viewport) !void {
        return r.vtable.record(r.ptr, c, try r.targetPtr(target), damage);
    }

    /// Draws a single canvas in one step.
    pub fn draw(r: Renderer, c: *const Canvas, target: anytype) !void {
        try r.prepare(&.{c});
        try r.record(c, target, null);
    }

    /// Renders all segments (`Canvas` and custom `GpuDraw`) into `target`,
    /// whose canvases have been prepared.
    pub fn render(r: Renderer, segments: []const Segment, target: anytype, damage: ?[]const Viewport) !void {
        const target_ptr = try r.targetPtr(target);
        for (segments) |s| switch (s) {
            .canvas => |c| try r.vtable.record(r.ptr, c, target_ptr, damage),
            .gpu => |g| {
                const active_vp = g.area.scissor orelse g.area.viewport;
                if (covers(damage, active_vp)) {
                    try g.f(g.ctx, target_ptr, g.area);
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
        try r.render(segments, target, damage);
    }

    pub fn deinit(r: Renderer) void {
        if (r.vtable.deinit) |f| f(r.ptr);
    }
};

test "drawing into the wrong kind of target is an error" {
    const Backend = struct {
        drawn: u32 = 0,
        pub fn prepare(_: *@This(), _: []const *const Canvas) !void {}
        pub fn record(b: *@This(), _: *const Canvas, _: *u32, _: ?[]const Viewport) !void {
            b.drawn += 1;
        }
    };
    var backend: Backend = .{};
    const r = Renderer.of(&backend);
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    var right: u32 = 0;
    var wrong: i64 = 0;
    try r.draw(&c, &right);
    try std.testing.expectError(error.WrongTarget, r.draw(&c, &wrong));
    try std.testing.expectEqual(@as(u32, 1), backend.drawn);
}
