//! Metal rendering backend for Facet's 2D `Canvas`, on macOS: the canvas's
//! batches drawn on the GPU with the shaders in `shaders/canvas.metal`
//! (compiled when the renderer starts), its glyph atlas and images in
//! textures.
//!
//! In a window (`renderMetal`) a frame is drawn into a texture the renderer
//! keeps, only where it changed, and then copied into the next drawable of
//! the window's `CAMetalLayer` and presented: no copy through the CPU. It
//! can also draw into an image on the CPU (`record`, as the OpenGL and
//! Vulkan renderers do), by way of a texture.
//!
//! Metal is loaded at run time (with the Objective-C runtime, `objc.zig`),
//! so nothing is needed to build it.
//!
//!     var mtl = try gfx.MetalRenderer.initDefault(gpa);
//!     defer mtl.deinit();
//!     ui.attachRenderer(mtl.renderer(), false);

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");
const software = @import("software.zig");

const Id = objc.Id;
const msg = objc.msg;
const Canvas = canvas_mod.Canvas;
const Viewport = renderer_mod.Viewport;
const Segment = renderer_mod.Segment;
const MetalTarget = renderer_mod.MetalTarget;

// Metal's constants.
const format_r8: u64 = 10; // MTLPixelFormatR8Unorm
const format_bgra8: u64 = 80; // MTLPixelFormatBGRA8Unorm
const usage_read: u64 = 1; // MTLTextureUsageShaderRead
const usage_render: u64 = 4; // MTLTextureUsageRenderTarget
/// Where textures the CPU reads or writes are kept: in memory both share
/// on Apple's GPUs; on others, a copy on each (kept in step by Metal).
const storage_cpu: u64 = if (builtin.cpu.arch == .aarch64) 0 else 1; // Shared, Managed
const managed = storage_cpu == 1;
/// Vertex buffers, written by the CPU only.
const buffer_options: u64 = 1; // MTLResourceCPUCacheModeWriteCombined (shared)
const load_load: u64 = 1;
const store_store: u64 = 1;
const triangles: u64 = 3;

const Origin = extern struct { x: u64, y: u64, z: u64 = 0 };
const Size = extern struct { width: u64, height: u64, depth: u64 = 1 };
const Region = extern struct { origin: Origin, size: Size };
const ScissorRect = extern struct { x: u64, y: u64, width: u64, height: u64 };
const MtlViewport = extern struct { x: f64, y: f64, width: f64, height: f64, znear: f64, zfar: f64 };

fn regionOf(v: Viewport) Region {
    return .{ .origin = .{ .x = @intCast(v.x), .y = @intCast(v.y) }, .size = .{ .width = v.width, .height = v.height } };
}

/// Room in each frame's vertex buffer for the quads that clear.
const clear_bytes = renderer_mod.max_uncovered * 6 * shaders.solid_floats * 4 + 16;

pub const MetalRenderer = struct {
    gpa: std.mem.Allocator,
    device: Id,
    queue: Id,
    pipelines: Pipelines = .{},
    nearest: Id = null,
    linear: Id = null,
    /// A vertex buffer for each frame that may be on the GPU at once, and
    /// the work drawing it (waited for before it is written again).
    slots: [3]Slot = @splat(.{}),
    slot: usize = 0,
    cursor: usize = 0,
    atlas_tex: Id = null,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    images: std.AutoHashMapUnmanaged(u64, Id) = .empty,
    /// The window's frame (kept from one to the next, so only what changed
    /// is drawn), and the texture `record` draws in for the CPU.
    screen: Frame = .{},
    offscreen: Frame = .{},
    /// A frame's pixels on the CPU, for GPU draws of widgets drawn there.
    scratch: std.ArrayList(u32) = .empty,

    const Pipelines = struct {
        shape: Id = null,
        solid: Id = null,
        @"opaque": Id = null,
        text: Id = null,
        image: Id = null,
    };

    const Slot = struct {
        buffer: Id = null,
        capacity: usize = 0,
        cmd: Id = null,
    };

    const Frame = struct {
        tex: Id = null,
        width: u32 = 0,
        height: u32 = 0,
    };

    pub const backend: renderer_mod.RenderBackend = .metal;

    /// The system's default GPU, its shaders compiled; an error if there
    /// is none (or this is not macOS).
    pub fn initDefault(gpa: std.mem.Allocator) !MetalRenderer {
        if (builtin.os.tag != .macos) return error.Unsupported;
        try objc.load();
        const pool = objc.push();
        defer objc.pop(pool);
        const create = objc.symbol(*const fn () callconv(.c) Id, "MTLCreateSystemDefaultDevice") orelse return error.NoMetal;
        const device = create() orelse return error.NoMetalDevice;
        var r: MetalRenderer = .{ .gpa = gpa, .device = device, .queue = msg(Id, device, "newCommandQueue", .{}) };
        errdefer r.deinit();
        if (r.queue == null) return error.NoMetalQueue;

        var err: Id = null;
        const lib = msg(Id, device, "newLibraryWithSource:options:error:", .{ objc.nsString(shaders.msl), @as(Id, null), &err });
        if (lib == null) {
            logError("compiling the shaders", err);
            return error.MetalShaderFailed;
        }
        defer objc.release(lib);
        r.pipelines = .{
            .shape = try r.pipeline(lib, "shape_vs", "shape_fs", true),
            .solid = try r.pipeline(lib, "solid_vs", "solid_fs", true),
            .@"opaque" = try r.pipeline(lib, "solid_vs", "solid_fs", false),
            .text = try r.pipeline(lib, "text_vs", "text_fs", true),
            .image = try r.pipeline(lib, "text_vs", "image_fs", true),
        };
        r.nearest = r.sampler(0);
        r.linear = r.sampler(1);
        if (r.nearest == null or r.linear == null) return error.MetalSamplerFailed;
        return r;
    }

    pub fn deinit(r: *MetalRenderer) void {
        if (r.device == null) return;
        const pool = objc.push();
        defer objc.pop(pool);
        r.waitIdle();
        for (&r.slots) |*s| objc.release(s.buffer);
        var it = r.images.valueIterator();
        while (it.next()) |tex| objc.release(tex.*);
        r.images.deinit(r.gpa);
        r.scratch.deinit(r.gpa);
        inline for (@typeInfo(Pipelines).@"struct".field_names) |name| objc.release(@field(r.pipelines, name));
        for ([_]Id{ r.nearest, r.linear, r.atlas_tex, r.screen.tex, r.offscreen.tex, r.queue, r.device }) |o| objc.release(o);
        r.device = null;
    }

    pub fn renderer(r: *MetalRenderer) renderer_mod.Renderer {
        return .of(r);
    }

    fn logError(what: []const u8, err: Id) void {
        const text = if (err == null) "" else objc.utf8(msg(Id, err, "localizedDescription", .{}));
        std.log.scoped(.metal).warn("{s}: {s}", .{ what, text });
    }

    fn pipeline(r: *MetalRenderer, lib: Id, vs: [:0]const u8, fs: [:0]const u8, blend: bool) !Id {
        const desc = objc.new(objc.class("MTLRenderPipelineDescriptor"));
        defer objc.release(desc);
        const v = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(vs)});
        defer objc.release(v);
        const f = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(fs)});
        defer objc.release(f);
        if (v == null or f == null) return error.MetalShaderFailed;
        msg(void, desc, "setVertexFunction:", .{v});
        msg(void, desc, "setFragmentFunction:", .{f});
        const att = msg(Id, msg(Id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        msg(void, att, "setPixelFormat:", .{format_bgra8});
        if (blend) {
            // Source over, as the other renderers: colours not
            // premultiplied, the alpha kept for what is drawn over.
            msg(void, att, "setBlendingEnabled:", .{objc.yes});
            msg(void, att, "setSourceRGBBlendFactor:", .{@as(u64, 4)}); // SourceAlpha
            msg(void, att, "setDestinationRGBBlendFactor:", .{@as(u64, 5)}); // OneMinusSourceAlpha
            msg(void, att, "setSourceAlphaBlendFactor:", .{@as(u64, 1)}); // One
            msg(void, att, "setDestinationAlphaBlendFactor:", .{@as(u64, 5)});
        }
        var err: Id = null;
        const p = msg(Id, r.device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err });
        if (p == null) {
            logError("making a pipeline", err);
            return error.MetalPipelineFailed;
        }
        return p;
    }

    /// A sampler, nearest (0) or linear (1), clamped to the edges.
    fn sampler(r: *MetalRenderer, filter: u64) Id {
        const desc = objc.new(objc.class("MTLSamplerDescriptor"));
        defer objc.release(desc);
        msg(void, desc, "setMinFilter:", .{filter});
        msg(void, desc, "setMagFilter:", .{filter});
        msg(void, desc, "setSAddressMode:", .{@as(u64, 0)});
        msg(void, desc, "setTAddressMode:", .{@as(u64, 0)});
        return msg(Id, r.device, "newSamplerStateWithDescriptor:", .{desc});
    }

    fn texture(r: *MetalRenderer, format: u64, width: u32, height: u32, usage: u64) !Id {
        const desc = msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, @as(u64, width), @as(u64, height), objc.no });
        msg(void, desc, "setUsage:", .{usage});
        msg(void, desc, "setStorageMode:", .{storage_cpu});
        return msg(Id, r.device, "newTextureWithDescriptor:", .{desc}) orelse error.MetalTextureFailed;
    }

    // --- Work on the GPU ------------------------------------------------------------

    fn waitSlot(s: *Slot) void {
        const cmd = s.cmd orelse return;
        msg(void, cmd, "waitUntilCompleted", .{});
        objc.release(cmd);
        s.cmd = null;
    }

    /// Waits until the GPU has done all it was given.
    fn waitIdle(r: *MetalRenderer) void {
        for (&r.slots) |*s| waitSlot(s);
    }

    fn commandBuffer(r: *MetalRenderer) !Id {
        return msg(Id, r.queue, "commandBuffer", .{}) orelse error.MetalCommandBufferFailed;
    }

    /// A render pass drawing over what `tex` has.
    fn beginPass(cmd: Id, tex: Id, width: u32, height: u32) !Id {
        const pass = msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const att = msg(Id, msg(Id, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        msg(void, att, "setTexture:", .{tex});
        msg(void, att, "setLoadAction:", .{load_load});
        msg(void, att, "setStoreAction:", .{store_store});
        const enc = msg(Id, cmd, "renderCommandEncoderWithDescriptor:", .{pass}) orelse return error.MetalEncoderFailed;
        msg(void, enc, "setViewport:", .{MtlViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .znear = 0, .zfar = 1 }});
        return enc;
    }

    /// Commits `cmd` and waits for it, `frame`'s texture then readable on
    /// the CPU.
    fn finishForCpu(cmd: Id, frame: *const Frame) void {
        if (managed) {
            const blit = msg(Id, cmd, "blitCommandEncoder", .{});
            msg(void, blit, "synchronizeResource:", .{frame.tex});
            msg(void, blit, "endEncoding", .{});
        }
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});
    }

    /// Makes `frame` `width` by `height`; true if it is new (and so has
    /// nothing in it yet).
    fn ensureFrame(r: *MetalRenderer, frame: *Frame, width: u32, height: u32) !bool {
        if (frame.tex != null and frame.width == width and frame.height == height) return false;
        objc.release(frame.tex);
        frame.* = .{};
        frame.tex = try r.texture(format_bgra8, width, height, usage_read | usage_render);
        frame.width = width;
        frame.height = height;
        return true;
    }

    // --- Preparing a frame ------------------------------------------------------------

    /// Makes room for the frame's vertices (in a buffer the GPU has done
    /// with), and uploads the glyph atlas's new rows and new images.
    pub fn prepare(r: *MetalRenderer, canvases: []const *const Canvas) !void {
        const pool = objc.push();
        defer objc.pop(pool);
        r.slot = (r.slot + 1) % r.slots.len;
        const s = &r.slots[r.slot];
        waitSlot(s);
        var bytes: usize = clear_bytes;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        if (bytes > s.capacity) {
            objc.release(s.buffer);
            s.* = .{};
            const capacity = std.mem.alignForward(usize, bytes * 2, 64 * 1024);
            s.buffer = msg(Id, r.device, "newBufferWithLength:options:", .{ @as(u64, capacity), buffer_options }) orelse return error.MetalBufferFailed;
            s.capacity = capacity;
        }
        r.cursor = 0;
        for (canvases) |c| if (c.atlas) |a| try r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *MetalRenderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        if (r.atlas_tex == null) {
            r.atlas_tex = try r.texture(format_r8, w, h, usage_read);
            r.atlas_stale = all;
        }
        if (r.atlas != a) {
            r.atlas = a;
            a.dirty = all;
        }
        if (a.dirty) |d| {
            r.atlas_stale = if (r.atlas_stale) |old|
                .{ .x0 = @min(old.x0, d.x0), .y0 = @min(old.y0, d.y0), .x1 = @max(old.x1, d.x1), .y1 = @max(old.y1, d.y1) }
            else
                d;
            a.dirty = null;
        }
        const d = r.atlas_stale orelse return;
        r.atlas_stale = null;
        const y0: u32 = d.y0;
        const y1: u32 = @min(d.y1, h);
        if (y1 <= y0) return;
        // Not while a frame drawing with it is on the GPU.
        r.waitIdle();
        const region = regionOf(.{ .x = 0, .y = @intCast(y0), .width = w, .height = y1 - y0 });
        msg(void, r.atlas_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(u64, 0), a.pixels[y0 * w ..].ptr, @as(u64, w) });
    }

    fn uploadImages(r: *MetalRenderer, canvases: []const *const Canvas) !void {
        var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer used.deinit(r.gpa);
        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            try used.put(r.gpa, img.id, {});
        };
        // Those no longer drawn go (the GPU keeps them while it uses them).
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(r.gpa);
        var it = r.images.iterator();
        while (it.next()) |e| if (!used.contains(e.key_ptr.*)) try stale.append(r.gpa, e.key_ptr.*);
        for (stale.items) |id| objc.release(r.images.fetchRemove(id).?.value);

        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            if (r.images.contains(img.id) or img.width == 0 or img.height == 0) continue;
            // 0xAARRGGBB, little-endian: BGRA in memory, as the texture is.
            const tex = try r.texture(format_bgra8, img.width, img.height, usage_read);
            const region = regionOf(.{ .width = img.width, .height = img.height });
            msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(u64, 0), img.pixels.ptr, @as(u64, img.width) * 4 });
            try r.images.put(r.gpa, img.id, tex);
        };
    }

    // --- Drawing ----------------------------------------------------------------------

    /// Room for `len` bytes of vertices in this frame's buffer: where they
    /// go, and their offset in it.
    fn vertices(r: *MetalRenderer, len: usize) !struct { bytes: []u8, offset: u64 } {
        const s = &r.slots[r.slot];
        if (s.buffer == null or r.cursor + len > s.capacity) return error.NotPrepared;
        const base: [*]u8 = @ptrCast(msg(?*anyopaque, s.buffer, "contents", .{}) orelse return error.NotPrepared);
        const offset = r.cursor;
        r.cursor += std.mem.alignForward(usize, len, 16);
        return .{ .bytes = base[offset..][0..len], .offset = offset };
    }

    fn scissor(enc: Id, v: Viewport) void {
        msg(void, enc, "setScissorRect:", .{ScissorRect{ .x = @intCast(v.x), .y = @intCast(v.y), .width = v.width, .height = v.height }});
    }

    /// Fills `rects` (within `full`) with `color` (ARGB), as they are.
    fn encodeClear(r: *MetalRenderer, enc: Id, full: Viewport, color: u32, rects: []const Viewport) !void {
        var n: usize = 0;
        for (rects) |cr| {
            if (full.intersect(cr) != null) n += 1;
        }
        if (n == 0) return;
        n = @min(n, renderer_mod.max_uncovered);
        const per_rect = 6 * shaders.solid_floats;
        const v = try r.vertices(n * per_rect * 4);
        const floats: []align(1) f32 = std.mem.bytesAsSlice(f32, v.bytes);
        const rgba: [4]f32 = .{
            @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255,
            @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255,
            @as(f32, @floatFromInt(color & 0xff)) / 255,
            @as(f32, @floatFromInt(color >> 24)) / 255,
        };
        const fw: f32 = @floatFromInt(full.width);
        const fh: f32 = @floatFromInt(full.height);
        var i: usize = 0;
        for (rects) |cr| {
            const c = full.intersect(cr) orelse continue;
            if (i == n) break;
            const x0 = @as(f32, @floatFromInt(c.x)) / fw * 2 - 1;
            const x1 = @as(f32, @floatFromInt(c.x + @as(i32, @intCast(c.width)))) / fw * 2 - 1;
            const y0 = 1 - @as(f32, @floatFromInt(c.y)) / fh * 2;
            const y1 = 1 - @as(f32, @floatFromInt(c.y + @as(i32, @intCast(c.height)))) / fh * 2;
            const corners = [6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y0 }, .{ x1, y1 }, .{ x0, y1 } };
            for (corners, 0..) |p, k| {
                const at = i * per_rect + k * shaders.solid_floats;
                floats[at + 0] = p[0];
                floats[at + 1] = p[1];
                for (rgba, 0..) |ch, j| floats[at + 2 + j] = ch;
            }
            i += 1;
        }
        msg(void, enc, "setRenderPipelineState:", .{r.pipelines.@"opaque"});
        msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ r.slots[r.slot].buffer, v.offset, @as(u64, 0) });
        scissor(enc, full);
        msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), @as(u64, n * 6) });
    }

    /// Draws a prepared canvas's batches with `enc` (into a target `full`
    /// in size), within `damage` (all of it if null).
    fn encode(r: *MetalRenderer, enc: Id, c: *const Canvas, full: Viewport, damage: ?[]const Viewport) !void {
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (!renderer_mod.covers(damage, renderer_mod.scissor(area))) continue;
            const clip_vp = (if (b.clip) |clip| renderer_mod.scissor(clip) else full).intersect(full) orelse continue;

            const pipe = switch (b.kind) {
                .shape => r.pipelines.shape,
                .solid => r.pipelines.solid,
                .@"opaque" => r.pipelines.@"opaque",
                .text => r.pipelines.text,
                .image => r.pipelines.image,
            };
            const tex: Id, const smp: Id = switch (b.kind) {
                .text => .{ r.atlas_tex orelse continue, r.nearest },
                .image => .{ r.images.get((b.image orelse continue).id) orelse return error.NotPrepared, r.linear },
                else => .{ null, null },
            };

            const v = try r.vertices(data.len);
            @memcpy(v.bytes, data);
            msg(void, enc, "setRenderPipelineState:", .{pipe});
            msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ r.slots[r.slot].buffer, v.offset, @as(u64, 0) });
            if (tex != null) {
                msg(void, enc, "setFragmentTexture:atIndex:", .{ tex, @as(u64, 0) });
                msg(void, enc, "setFragmentSamplerState:atIndex:", .{ smp, @as(u64, 0) });
            }
            const count: u64 = b.vertexCount();
            if (damage) |list| {
                for (list) |d| {
                    const sc = clip_vp.intersect(d) orelse continue;
                    scissor(enc, sc);
                    msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), count });
                }
            } else {
                scissor(enc, clip_vp);
                msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), count });
            }
        }
    }

    /// Copies `region` of `img` into `frame`'s texture.
    fn upload(frame: *const Frame, img: software.Image, region: Viewport) void {
        const stride = img.rowStride();
        const at = @as(usize, @intCast(region.y)) * stride + @as(usize, @intCast(region.x));
        msg(void, frame.tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ regionOf(region), @as(u64, 0), img.pixels[at..].ptr, @as(u64, stride) * 4 });
    }

    /// Copies `region` of `frame`'s texture into `img` (the GPU done with
    /// it, see `finishForCpu`).
    fn download(frame: *const Frame, img: software.Image, region: Viewport) void {
        const stride = img.rowStride();
        const at = @as(usize, @intCast(region.y)) * stride + @as(usize, @intCast(region.x));
        msg(void, frame.tex, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ img.pixels[at..].ptr, @as(u64, stride) * 4, regionOf(region), @as(u64, 0) });
    }

    /// Renders a prepared 2D `Canvas` into `target: *software.Image`,
    /// keeping what is there and clipping to `damage` viewports when
    /// provided (by way of a texture: copied in, drawn on, copied back).
    pub fn record(r: *MetalRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
        if (target.width == 0 or target.height == 0) return;
        var has_work = false;
        for (c.batches.items) |*b| {
            if (b.floats.items.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (renderer_mod.covers(damage, renderer_mod.scissor(area))) {
                has_work = true;
                break;
            }
        }
        if (!has_work) return;
        const pool = objc.push();
        defer objc.pop(pool);
        _ = try r.ensureFrame(&r.offscreen, target.width, target.height);
        const full: Viewport = .{ .width = target.width, .height = target.height };
        const all = [1]Viewport{full};
        const regions = damage orelse &all;
        for (regions) |reg| if (full.intersect(reg)) |sc| upload(&r.offscreen, target.*, sc);
        const cmd = try r.commandBuffer();
        const enc = try beginPass(cmd, r.offscreen.tex, target.width, target.height);
        try r.encode(enc, c, full, damage);
        msg(void, enc, "endEncoding", .{});
        finishForCpu(cmd, &r.offscreen);
        for (regions) |reg| if (full.intersect(reg)) |sc| download(&r.offscreen, target.*, sc);
    }

    /// Renders a frame into the window's Metal layer (see
    /// `Renderer.renderMetal`): into the frame kept from the last, only
    /// within `damage` (all of it, if the frame is new), and that copied
    /// into the layer's next drawable and presented.
    pub fn renderMetal(r: *MetalRenderer, canvases: []const *const Canvas, segments: []const Segment, t: *const MetalTarget, clear: u32, clear_rects: []const Viewport, damage: []const Viewport) !void {
        if (t.width == 0 or t.height == 0) return;
        const pool = objc.push();
        defer objc.pop(pool);
        const layer: Id = t.layer;
        if (msg(Id, layer, "device", .{}) != r.device) {
            msg(void, layer, "setDevice:", .{r.device});
            msg(void, layer, "setPixelFormat:", .{format_bgra8});
            // Copied into, not only drawn in.
            msg(void, layer, "setFramebufferOnly:", .{objc.no});
        }
        try r.prepare(canvases);
        const fresh = try r.ensureFrame(&r.screen, t.width, t.height);
        const full: Viewport = .{ .width = t.width, .height = t.height };
        const all = [1]Viewport{full};
        var clear_buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        const dmg: []const Viewport = if (fresh) &all else damage;
        const clears = if (fresh) renderer_mod.uncovered(&clear_buf, &all, segments) else clear_rects;

        var cmd = try r.commandBuffer();
        var enc = try beginPass(cmd, r.screen.tex, t.width, t.height);
        try r.encodeClear(enc, full, clear, clears);
        var buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        for (segments, 0..) |seg, i| switch (seg) {
            .canvas => |c| {
                // Not under a GPU draw that covers it (as `Renderer.render`).
                const d = renderer_mod.uncovered(&buf, dmg, segments[i + 1 ..]);
                if (d.len == 0) continue;
                try r.encode(enc, c, full, d);
            },
            .gpu => |g| {
                const area = full.intersect(g.area.scissor orelse g.area.viewport) orelse continue;
                if (!renderer_mod.covers(dmg, area)) continue;
                // Drawn on the CPU: what is under it is finished first, and
                // what is over it drawn after.
                msg(void, enc, "endEncoding", .{});
                finishForCpu(cmd, &r.screen);
                try r.scratch.resize(r.gpa, @as(usize, t.width) * t.height);
                var img: software.Image = .{ .pixels = r.scratch.items, .width = t.width, .height = t.height };
                download(&r.screen, img, area);
                try g.f(g.ctx, @ptrCast(&img), g.area);
                upload(&r.screen, img, area);
                cmd = try r.commandBuffer();
                enc = try beginPass(cmd, r.screen.tex, t.width, t.height);
            },
        };
        msg(void, enc, "endEncoding", .{});

        // Into the window. If there is no drawable to be had, the frame is
        // kept, and shown with the next.
        if (msg(Id, layer, "nextDrawable", .{})) |drawable| {
            const dst = msg(Id, drawable, "texture", .{});
            const w = @min(t.width, msg(u64, dst, "width", .{}));
            const h = @min(t.height, msg(u64, dst, "height", .{}));
            const blit = msg(Id, cmd, "blitCommandEncoder", .{});
            msg(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
                r.screen.tex, @as(u64, 0), @as(u64, 0), Origin{ .x = 0, .y = 0 }, Size{ .width = w, .height = h }, dst, @as(u64, 0), @as(u64, 0), Origin{ .x = 0, .y = 0 },
            });
            msg(void, blit, "endEncoding", .{});
            msg(void, cmd, "presentDrawable:", .{drawable});
        }
        msg(void, cmd, "commit", .{});
        r.slots[r.slot].cmd = objc.retain(cmd);
    }
};

test "regions are Metal's, a pixel rectangle's origin and size" {
    const reg = regionOf(.{ .x = 3, .y = 4, .width = 5, .height = 6 });
    try std.testing.expectEqual(@as(u64, 3), reg.origin.x);
    try std.testing.expectEqual(@as(u64, 4), reg.origin.y);
    try std.testing.expectEqual(@as(u64, 5), reg.size.width);
    try std.testing.expectEqual(@as(u64, 6), reg.size.height);
    try std.testing.expectEqual(@as(u64, 1), reg.size.depth);
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Region));
    if (builtin.os.tag != .macos) try std.testing.expectError(error.Unsupported, MetalRenderer.initDefault(std.testing.allocator));
}
