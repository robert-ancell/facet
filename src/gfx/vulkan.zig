//! Vulkan 1.1+ rendering backend for Facet's 2D `Canvas`.
//!
//! Uses a runtime `GetDeviceProcAddr` loader and the SPIR-V shaders compiled
//! at build time from `src/gfx/shaders/*.zig` (`shaders.shape_spv`,
//! `shaders.solid_spv`, `shaders.text_spv`, `shaders.image_spv`), so no
//! Vulkan SDK headers or link libraries are required at compile time.
//!
//!     var vk = try gfx.vulkan.VulkanRenderer.init(gpa, device, get_device_proc, options);
//!     defer vk.deinit();
//!     const target: gfx.vulkan.Target = .{ .cmd = cmd_buf, .width = w, .height = h };
//!     try ui.renderWith(vk.renderer(), &target, null);

const std = @import("std");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");

const Canvas = canvas_mod.Canvas;
const Viewport = renderer_mod.Viewport;

pub const VkFlags = u32;
pub const VkBool32 = u32;
pub const VkDeviceSize = u64;
pub const VK_TRUE: VkBool32 = 1;
pub const VK_FALSE: VkBool32 = 0;

pub const VkResult = enum(i32) {
    success = 0,
    _,
};

pub const VkDevice = *opaque {};
pub const VkCommandBuffer = *opaque {};
pub const VkRenderPass = u64;
pub const VkPipeline = u64;
pub const VkPipelineLayout = u64;
pub const VkShaderModule = u64;
pub const VkBuffer = u64;
pub const VkDeviceMemory = u64;
pub const VkDescriptorSetLayout = u64;
pub const VkDescriptorSet = u64;

pub const VK_NULL_HANDLE: u64 = 0;

pub const VkStructureType = enum(u32) {
    shader_module_create_info = 16,
    buffer_create_info = 12,
    memory_allocate_info = 5,
    _,
};

pub const VkBufferUsageFlags = VkFlags;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: VkBufferUsageFlags = 0x00000080;

pub const VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType = .shader_module_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkBufferCreateInfo = extern struct {
    sType: VkStructureType = .buffer_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    size: VkDeviceSize,
    usage: VkBufferUsageFlags,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

pub const VkMemoryRequirements = extern struct {
    size: VkDeviceSize,
    alignment: VkDeviceSize,
    memoryTypeBits: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType = .memory_allocate_info,
    pNext: ?*const anyopaque = null,
    allocationSize: VkDeviceSize,
    memoryTypeIndex: u32,
};

pub const VkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32 = 0.0,
    maxDepth: f32 = 1.0,
};

pub const VkOffset2D = extern struct {
    x: i32,
    y: i32,
};

pub const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const VkRect2D = extern struct {
    offset: VkOffset2D,
    extent: VkExtent2D,
};

pub const VK_PIPELINE_BIND_POINT_GRAPHICS: u32 = 0;

pub const GetDeviceProcAddr = *const fn (device: VkDevice, name: [*:0]const u8) callconv(.c) ?*const anyopaque;

pub const DeviceProcs = struct {
    CreateShaderModule: *const fn (VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) callconv(.c) VkResult,
    DestroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void,
    CreateBuffer: *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.c) VkResult,
    DestroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    GetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void,
    AllocateMemory: *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.c) VkResult,
    FreeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void,
    BindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize) callconv(.c) VkResult,
    MapMemory: *const fn (VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, *?*anyopaque) callconv(.c) VkResult,
    UnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    CmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    CmdSetViewport: *const fn (VkCommandBuffer, u32, u32, [*]const VkViewport) callconv(.c) void,
    CmdSetScissor: *const fn (VkCommandBuffer, u32, u32, [*]const VkRect2D) callconv(.c) void,
    CmdBindVertexBuffers: *const fn (VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const VkDeviceSize) callconv(.c) void,
    CmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?[*]const u32) callconv(.c) void,
    CmdDraw: *const fn (VkCommandBuffer, u32, u32, u32, u32) callconv(.c) void,

    pub fn load(device: VkDevice, get_proc: GetDeviceProcAddr) !DeviceProcs {
        var p: DeviceProcs = undefined;
        inline for (@typeInfo(DeviceProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(device, name) orelse return error.MissingVulkanFunction;
            @field(p, field_name) = @ptrCast(sym);
        }
        return p;
    }
};

/// Pipelines and descriptor callbacks configured by the host Vulkan setup.
pub const Pipelines = struct {
    layout: VkPipelineLayout = VK_NULL_HANDLE,
    shape: VkPipeline = VK_NULL_HANDLE,
    solid: VkPipeline = VK_NULL_HANDLE,
    @"opaque": VkPipeline = VK_NULL_HANDLE,
    text: VkPipeline = VK_NULL_HANDLE,
    image: VkPipeline = VK_NULL_HANDLE,
};

/// Optional texture upload hooks for the host Vulkan memory/descriptor manager.
pub const TextureHooks = struct {
    ctx: ?*anyopaque = null,
    /// Uploads dirty rows `[y0..y1)` of the 8-bit `atlas` and returns the
    /// descriptor set to bind for `.text` draws.
    uploadAtlas: ?*const fn (ctx: ?*anyopaque, pixels: []const u8, width: u32, height: u32, y0: u32, y1: u32) anyerror!VkDescriptorSet = null,
    /// Uploads or looks up an `0xAARRGGBB` `Image` and returns the descriptor
    /// set to bind for `.image` draws.
    acquireImage: ?*const fn (ctx: ?*anyopaque, id: u64, pixels: []const u32, width: u32, height: u32) anyerror!VkDescriptorSet = null,
    /// Releases an image texture no longer drawn.
    releaseImage: ?*const fn (ctx: ?*anyopaque, id: u64) void = null,
};

pub const Options = struct {
    /// Host-visible coherent memory type index for streaming vertex buffers.
    host_visible_memory_type: u32 = 0,
    pipelines: Pipelines = .{},
    textures: TextureHooks = .{},
};

/// Active Vulkan command buffer target for `VulkanRenderer.record`.
pub const Target = struct {
    cmd: VkCommandBuffer,
    width: u32,
    height: u32,
    /// When true (default, Vulkan 1.1+ / `VK_KHR_maintenance1`), uses a negative
    /// viewport height so clip-space Y matches OpenGL/Canvas (+1 at top).
    flip_viewport_y: bool = true,
};

pub const ShaderModules = struct {
    shape: VkShaderModule,
    solid: VkShaderModule,
    text: VkShaderModule,
    image: VkShaderModule,

    pub fn deinit(m: ShaderModules, device: VkDevice, vk: *const DeviceProcs) void {
        vk.DestroyShaderModule(device, m.shape, null);
        vk.DestroyShaderModule(device, m.solid, null);
        vk.DestroyShaderModule(device, m.text, null);
        vk.DestroyShaderModule(device, m.image, null);
    }
};

pub const VulkanRenderer = struct {
    gpa: std.mem.Allocator,
    device: VkDevice,
    vk: DeviceProcs,
    shader_modules: ShaderModules,
    pipelines: Pipelines,
    textures: TextureHooks,
    host_memory_type: u32,

    vbo: VkBuffer = VK_NULL_HANDLE,
    vbo_mem: VkDeviceMemory = VK_NULL_HANDLE,
    vbo_map: []u8 = &.{},
    cursor: usize = 0,

    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    atlas_set: VkDescriptorSet = VK_NULL_HANDLE,
    images: std.AutoHashMapUnmanaged(u64, VkDescriptorSet) = .empty,

    pub fn init(gpa: std.mem.Allocator, device: VkDevice, get_proc: GetDeviceProcAddr, options: Options) !VulkanRenderer {
        const vk = try DeviceProcs.load(device, get_proc);
        return initWithProcs(gpa, device, vk, options);
    }

    pub fn initWithProcs(gpa: std.mem.Allocator, device: VkDevice, vk: DeviceProcs, options: Options) !VulkanRenderer {
        const shape_mod = try createShaderModule(device, &vk, &shaders.shape_spv);
        errdefer vk.DestroyShaderModule(device, shape_mod, null);
        const solid_mod = try createShaderModule(device, &vk, &shaders.solid_spv);
        errdefer vk.DestroyShaderModule(device, solid_mod, null);
        const text_mod = try createShaderModule(device, &vk, &shaders.text_spv);
        errdefer vk.DestroyShaderModule(device, text_mod, null);
        const image_mod = try createShaderModule(device, &vk, &shaders.image_spv);
        errdefer vk.DestroyShaderModule(device, image_mod, null);

        return .{
            .gpa = gpa,
            .device = device,
            .vk = vk,
            .shader_modules = .{
                .shape = shape_mod,
                .solid = solid_mod,
                .text = text_mod,
                .image = image_mod,
            },
            .pipelines = options.pipelines,
            .textures = options.textures,
            .host_memory_type = options.host_visible_memory_type,
        };
    }

    pub fn deinit(r: *VulkanRenderer) void {
        if (r.textures.releaseImage) |rel| {
            var it = r.images.keyIterator();
            while (it.next()) |id| rel(r.textures.ctx, id.*);
        }
        r.images.deinit(r.gpa);
        r.destroyVbo();
        r.shader_modules.deinit(r.device, &r.vk);
    }

    pub fn renderer(r: *VulkanRenderer) renderer_mod.Renderer {
        return .of(r);
    }

    fn createShaderModule(device: VkDevice, vk: *const DeviceProcs, code: []align(4) const u8) !VkShaderModule {
        var info: VkShaderModuleCreateInfo = .{
            .codeSize = code.len,
            .pCode = @ptrCast(code.ptr),
        };
        var out: VkShaderModule = VK_NULL_HANDLE;
        if (vk.CreateShaderModule(device, &info, null, &out) != .success) {
            return error.VkCreateShaderModuleFailed;
        }
        return out;
    }

    fn destroyVbo(r: *VulkanRenderer) void {
        if (r.vbo_map.len > 0) {
            r.vk.UnmapMemory(r.device, r.vbo_mem);
            r.vbo_map = &.{};
        }
        if (r.vbo != VK_NULL_HANDLE) {
            r.vk.DestroyBuffer(r.device, r.vbo, null);
            r.vbo = VK_NULL_HANDLE;
        }
        if (r.vbo_mem != VK_NULL_HANDLE) {
            r.vk.FreeMemory(r.device, r.vbo_mem, null);
            r.vbo_mem = VK_NULL_HANDLE;
        }
    }

    fn ensureVbo(r: *VulkanRenderer, min_bytes: usize) !void {
        if (r.vbo_map.len >= min_bytes) return;
        r.destroyVbo();
        const cap = std.mem.alignForward(usize, min_bytes * 2, 64 * 1024);
        var buf_info: VkBufferCreateInfo = .{
            .size = cap,
            .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        };
        var buf: VkBuffer = VK_NULL_HANDLE;
        if (r.vk.CreateBuffer(r.device, &buf_info, null, &buf) != .success) return error.VkCreateBufferFailed;
        errdefer r.vk.DestroyBuffer(r.device, buf, null);

        var req: VkMemoryRequirements = undefined;
        r.vk.GetBufferMemoryRequirements(r.device, buf, &req);
        var alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, cap),
            .memoryTypeIndex = r.host_memory_type,
        };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (r.vk.AllocateMemory(r.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer r.vk.FreeMemory(r.device, mem, null);

        if (r.vk.BindBufferMemory(r.device, buf, mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (r.vk.MapMemory(r.device, mem, 0, cap, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;

        r.vbo = buf;
        r.vbo_mem = mem;
        r.vbo_map = @as([*]u8, @ptrCast(ptr.?))[0..cap];
    }

    pub fn prepare(r: *VulkanRenderer, canvases: []const *const Canvas) !void {
        var bytes: usize = 0;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        r.cursor = 0;
        if (bytes > 0) try r.ensureVbo(bytes);
        for (canvases) |c| if (c.atlas) |a| try r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *VulkanRenderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
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
        if (r.textures.uploadAtlas) |upload| {
            r.atlas_set = try upload(r.textures.ctx, a.pixels, w, h, d.y0, @min(d.y1, h));
        }
        r.atlas_stale = null;
    }

    fn uploadImages(r: *VulkanRenderer, canvases: []const *const Canvas) !void {
        var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer used.deinit(r.gpa);
        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            try used.put(r.gpa, img.id, {});
        };
        var stale_ids: std.ArrayList(u64) = .empty;
        defer stale_ids.deinit(r.gpa);
        var it = r.images.iterator();
        while (it.next()) |e| if (!used.contains(e.key_ptr.*)) try stale_ids.append(r.gpa, e.key_ptr.*);
        for (stale_ids.items) |id| {
            _ = r.images.remove(id);
            if (r.textures.releaseImage) |rel| rel(r.textures.ctx, id);
        }

        if (r.textures.acquireImage) |acq| {
            for (canvases) |c| for (c.batches.items) |*b| {
                const img = b.image orelse continue;
                if (r.images.contains(img.id)) continue;
                const set = try acq(r.textures.ctx, img.id, img.pixels, img.width, img.height);
                try r.images.put(r.gpa, img.id, set);
            };
        }
    }

    pub fn record(r: *VulkanRenderer, c: *const Canvas, target: *const Target, damage: ?[]const Viewport) !void {
        if (target.width == 0 or target.height == 0) return;
        const w_f: f32 = @floatFromInt(target.width);
        const h_f: f32 = @floatFromInt(target.height);
        const vp = [1]VkViewport{if (target.flip_viewport_y) .{
            .x = 0,
            .y = h_f,
            .width = w_f,
            .height = -h_f,
        } else .{
            .x = 0,
            .y = 0,
            .width = w_f,
            .height = h_f,
        }};
        r.vk.CmdSetViewport(target.cmd, 0, 1, &vp);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };

        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            const batch_vp = renderer_mod.scissor(area);
            if (!renderer_mod.covers(damage, batch_vp)) continue;
            if (r.cursor + data.len > r.vbo_map.len) return error.NotPrepared;

            @memcpy(r.vbo_map[r.cursor..][0..data.len], data);
            const byte_offset: VkDeviceSize = @intCast(r.cursor);
            r.cursor += std.mem.alignForward(usize, data.len, 16);

            const pipeline: VkPipeline = switch (b.kind) {
                .shape => r.pipelines.shape,
                .solid => r.pipelines.solid,
                .@"opaque" => if (r.pipelines.@"opaque" != VK_NULL_HANDLE) r.pipelines.@"opaque" else r.pipelines.solid,
                .text => r.pipelines.text,
                .image => r.pipelines.image,
            };
            r.vk.CmdBindPipeline(target.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

            const bufs = [1]VkBuffer{r.vbo};
            const offs = [1]VkDeviceSize{byte_offset};
            r.vk.CmdBindVertexBuffers(target.cmd, 0, 1, &bufs, &offs);

            switch (b.kind) {
                .text => if (r.atlas_set != VK_NULL_HANDLE) {
                    const sets = [1]VkDescriptorSet{r.atlas_set};
                    r.vk.CmdBindDescriptorSets(target.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipelines.layout, 0, 1, &sets, 0, null);
                },
                .image => {
                    const img = b.image orelse continue;
                    if (r.images.get(img.id)) |set| {
                        const sets = [1]VkDescriptorSet{set};
                        r.vk.CmdBindDescriptorSets(target.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipelines.layout, 0, 1, &sets, 0, null);
                    }
                },
                else => {},
            }

            const clip_vp = if (b.clip) |clip| renderer_mod.scissor(clip) else full_vp;
            const count = b.vertexCount();
            if (damage) |dmg_list| {
                for (dmg_list) |dmg| {
                    const sc = clip_vp.intersect(dmg) orelse continue;
                    const rect = [1]VkRect2D{.{
                        .offset = .{ .x = sc.x, .y = sc.y },
                        .extent = .{ .width = sc.width, .height = sc.height },
                    }};
                    r.vk.CmdSetScissor(target.cmd, 0, 1, &rect);
                    r.vk.CmdDraw(target.cmd, count, 1, 0, 0);
                }
            } else {
                const rect = [1]VkRect2D{.{
                    .offset = .{ .x = clip_vp.x, .y = clip_vp.y },
                    .extent = .{ .width = clip_vp.width, .height = clip_vp.height },
                }};
                r.vk.CmdSetScissor(target.cmd, 0, 1, &rect);
                r.vk.CmdDraw(target.cmd, count, 1, 0, 0);
            }
        }
    }
};

test "VulkanRenderer creates SPIR-V shader modules, prepares vertex buffers, and records draws" {
    const MockVk = struct {
        var next_handle: u64 = 1;
        var draws: usize = 0;
        var last_scissor: VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 0, .height = 0 } };
        var backing_mem: [128 * 1024]u8 = undefined;

        fn createShaderModule(_: VkDevice, info: *const VkShaderModuleCreateInfo, _: ?*const anyopaque, out: *VkShaderModule) callconv(.c) VkResult {
            // Verify SPIR-V magic number (0x07230203)
            if (info.codeSize < 4 or info.pCode[0] != 0x07230203) return @fromBackingInt(-1);
            out.* = next_handle;
            next_handle += 1;
            return .success;
        }
        fn destroyShaderModule(_: VkDevice, _: VkShaderModule, _: ?*const anyopaque) callconv(.c) void {}
        fn createBuffer(_: VkDevice, _: *const VkBufferCreateInfo, _: ?*const anyopaque, out: *VkBuffer) callconv(.c) VkResult {
            out.* = next_handle;
            next_handle += 1;
            return .success;
        }
        fn destroyBuffer(_: VkDevice, _: VkBuffer, _: ?*const anyopaque) callconv(.c) void {}
        fn getBufferMemoryRequirements(_: VkDevice, _: VkBuffer, req: *VkMemoryRequirements) callconv(.c) void {
            req.* = .{ .size = backing_mem.len, .alignment = 16, .memoryTypeBits = 1 };
        }
        fn allocateMemory(_: VkDevice, _: *const VkMemoryAllocateInfo, _: ?*const anyopaque, out: *VkDeviceMemory) callconv(.c) VkResult {
            out.* = next_handle;
            next_handle += 1;
            return .success;
        }
        fn freeMemory(_: VkDevice, _: VkDeviceMemory, _: ?*const anyopaque) callconv(.c) void {}
        fn bindBufferMemory(_: VkDevice, _: VkBuffer, _: VkDeviceMemory, _: VkDeviceSize) callconv(.c) VkResult {
            return .success;
        }
        fn mapMemory(_: VkDevice, _: VkDeviceMemory, _: VkDeviceSize, _: VkDeviceSize, _: VkFlags, out: *?*anyopaque) callconv(.c) VkResult {
            out.* = &backing_mem;
            return .success;
        }
        fn unmapMemory(_: VkDevice, _: VkDeviceMemory) callconv(.c) void {}
        fn cmdBindPipeline(_: VkCommandBuffer, _: u32, _: VkPipeline) callconv(.c) void {}
        fn cmdSetViewport(_: VkCommandBuffer, _: u32, _: u32, _: [*]const VkViewport) callconv(.c) void {}
        fn cmdSetScissor(_: VkCommandBuffer, _: u32, _: u32, rects: [*]const VkRect2D) callconv(.c) void {
            last_scissor = rects[0];
        }
        fn cmdBindVertexBuffers(_: VkCommandBuffer, _: u32, _: u32, _: [*]const VkBuffer, _: [*]const VkDeviceSize) callconv(.c) void {}
        fn cmdBindDescriptorSets(_: VkCommandBuffer, _: u32, _: VkPipelineLayout, _: u32, _: u32, _: [*]const VkDescriptorSet, _: u32, _: ?[*]const u32) callconv(.c) void {}
        fn cmdDraw(_: VkCommandBuffer, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {
            draws += 1;
        }
    };

    var dummy_dev: u8 = 0;
    var dummy_cmd: u8 = 0;
    var vk_renderer = try VulkanRenderer.initWithProcs(
        std.testing.allocator,
        @ptrCast(&dummy_dev),
        .{
            .CreateShaderModule = MockVk.createShaderModule,
            .DestroyShaderModule = MockVk.destroyShaderModule,
            .CreateBuffer = MockVk.createBuffer,
            .DestroyBuffer = MockVk.destroyBuffer,
            .GetBufferMemoryRequirements = MockVk.getBufferMemoryRequirements,
            .AllocateMemory = MockVk.allocateMemory,
            .FreeMemory = MockVk.freeMemory,
            .BindBufferMemory = MockVk.bindBufferMemory,
            .MapMemory = MockVk.mapMemory,
            .UnmapMemory = MockVk.unmapMemory,
            .CmdBindPipeline = MockVk.cmdBindPipeline,
            .CmdSetViewport = MockVk.cmdSetViewport,
            .CmdSetScissor = MockVk.cmdSetScissor,
            .CmdBindVertexBuffers = MockVk.cmdBindVertexBuffers,
            .CmdBindDescriptorSets = MockVk.cmdBindDescriptorSets,
            .CmdDraw = MockVk.cmdDraw,
        },
        .{},
    );
    defer vk_renderer.deinit();

    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(200, 100);
    c.setClip(.{ .x = 12, .y = 18, .w = 60, .h = 40 });
    c.fillRoundedRect(.{ .x = 12, .y = 18, .w = 60, .h = 40 }, .all(8), .rgb(0x6750a4));

    const target: Target = .{ .cmd = @ptrCast(&dummy_cmd), .width = 200, .height = 100 };
    try vk_renderer.renderer().draw(&c, &target);
    try std.testing.expectEqual(@as(usize, 3), MockVk.draws);
    try std.testing.expectEqual(@as(i32, 12), MockVk.last_scissor.offset.x);
    try std.testing.expectEqual(@as(i32, 18), MockVk.last_scissor.offset.y);
    try std.testing.expectEqual(@as(u32, 60), MockVk.last_scissor.extent.width);
    try std.testing.expectEqual(@as(u32, 40), MockVk.last_scissor.extent.height);
}
