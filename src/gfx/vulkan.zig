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
const software = @import("software.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Viewport = renderer_mod.Viewport;
const GpuArea = renderer_mod.GpuArea;

pub const VkFlags = u32;
pub const VkBool32 = u32;
pub const VkDeviceSize = u64;
pub const VK_TRUE: VkBool32 = 1;
pub const VK_FALSE: VkBool32 = 0;

pub const VkResult = enum(i32) {
    success = 0,
    _,
};

pub const VkInstance = *opaque {};
pub const VkPhysicalDevice = *opaque {};
pub const VkDevice = *opaque {};
pub const VkQueue = *opaque {};
pub const VkCommandBuffer = *opaque {};
pub const VkCommandPool = u64;
pub const VkRenderPass = u64;
pub const VkFramebuffer = u64;
pub const VkImage = u64;
pub const VkImageView = u64;
pub const VkPipeline = u64;
pub const VkPipelineCache = u64;
pub const VkPipelineLayout = u64;
pub const VkShaderModule = u64;
pub const VkBuffer = u64;
pub const VkDeviceMemory = u64;
pub const VkDescriptorSetLayout = u64;
pub const VkDescriptorPool = u64;
pub const VkDescriptorSet = u64;
pub const VkSampler = u64;
pub const VkFence = u64;

pub const VK_NULL_HANDLE: u64 = 0;

pub const VkStructureType = enum(u32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    buffer_create_info = 12,
    image_create_info = 14,
    image_view_create_info = 15,
    shader_module_create_info = 16,
    pipeline_shader_stage_create_info = 18,
    pipeline_vertex_input_state_create_info = 19,
    pipeline_input_assembly_state_create_info = 20,
    pipeline_viewport_state_create_info = 22,
    pipeline_rasterization_state_create_info = 23,
    pipeline_multisample_state_create_info = 24,
    pipeline_depth_stencil_state_create_info = 25,
    pipeline_color_blend_state_create_info = 26,
    pipeline_dynamic_state_create_info = 27,
    graphics_pipeline_create_info = 28,
    pipeline_layout_create_info = 30,
    sampler_create_info = 31,
    descriptor_set_layout_create_info = 32,
    descriptor_pool_create_info = 33,
    descriptor_set_allocate_info = 34,
    write_descriptor_set = 35,
    framebuffer_create_info = 37,
    render_pass_create_info = 38,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    render_pass_begin_info = 43,
    image_memory_barrier = 45,
    _,
};

pub const VkBufferUsageFlags = VkFlags;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: VkBufferUsageFlags = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: VkBufferUsageFlags = 0x00000002;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT: VkBufferUsageFlags = 0x00000010;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT: VkBufferUsageFlags = 0x00000040;
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

/// Active Vulkan command buffer target for `VulkanRenderer.recordTarget`.
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
    owned: ?*Owned2DContext = null,

    vbo: VkBuffer = VK_NULL_HANDLE,
    vbo_mem: VkDeviceMemory = VK_NULL_HANDLE,
    vbo_map: []u8 = &.{},
    cursor: usize = 0,

    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    atlas_set: VkDescriptorSet = VK_NULL_HANDLE,
    images: std.AutoHashMapUnmanaged(u64, VkDescriptorSet) = .empty,

    /// Initializes a self-contained Vulkan 1.1+ 2D renderer that compiles SPIR-V
    /// pipelines (`shape`, `solid`, `opaque`, `text`, `image`), manages glyph
    /// atlas and image textures, and renders `Canvas` batches into `*software.Image`.
    pub fn initDefault(gpa: std.mem.Allocator) !VulkanRenderer {
        const owned = try Owned2DContext.create(gpa);
        errdefer owned.destroy();

        const dev_procs = try DeviceProcs.load(owned.device, owned.inst_procs.GetDeviceProcAddr);
        var r = try initWithProcs(gpa, owned.device, dev_procs, .{
            .host_visible_memory_type = owned.host_mem_type,
            .pipelines = .{},
            .textures = owned.textureHooks(),
        });
        errdefer r.deinit();

        try owned.initPipelines(r.shader_modules);
        r.pipelines = owned.pipelines;
        r.owned = owned;
        return r;
    }

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
        if (r.owned) |owned| {
            _ = owned.vk.DeviceWaitIdle(owned.device);
        }
        if (r.textures.releaseImage) |rel| {
            var it = r.images.keyIterator();
            while (it.next()) |id| rel(r.textures.ctx, id.*);
        }
        r.images.deinit(r.gpa);
        r.destroyVbo();
        r.shader_modules.deinit(r.device, &r.vk);
        if (r.owned) |owned| {
            owned.destroy();
            r.owned = null;
        }
    }

    pub const backend: renderer_mod.RenderBackend = .vulkan;

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

    /// Renders a prepared 2D `Canvas` into `target: *software.Image`, preserving
    /// existing background pixels and clipping to `damage` viewports when provided.
    pub fn record(r: *VulkanRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
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

        if (r.owned) |ctx| {
            try ctx.renderCanvasToImage(r, c, target, damage);
        } else {
            var dummy_cmd: u8 = 0;
            const cmd_target: Target = .{
                .cmd = @ptrCast(&dummy_cmd),
                .width = target.width,
                .height = target.height,
            };
            try r.recordTarget(c, &cmd_target, damage);
        }
    }

    pub fn recordTarget(r: *VulkanRenderer, c: *const Canvas, target: *const Target, damage: ?[]const Viewport) !void {
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

// --- Offscreen Vulkan 1.1+ Context for `VulkanRenderer` and `VulkanArea` -----

pub const VK_FORMAT_R8_UNORM: u32 = 9;
pub const VK_FORMAT_B8G8R8A8_UNORM: u32 = 44;
pub const VK_FORMAT_R32_SFLOAT: u32 = 100;
pub const VK_FORMAT_R32G32_SFLOAT: u32 = 103;
pub const VK_FORMAT_R32G32B32_SFLOAT: u32 = 106;
pub const VK_FORMAT_R32G32B32A32_SFLOAT: u32 = 109;
pub const VK_FORMAT_D32_SFLOAT: u32 = 126;

pub const VK_COMPONENT_SWIZZLE_R: u32 = 3;

pub const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
pub const VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: u32 = 3;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;

pub const VK_ATTACHMENT_LOAD_OP_LOAD: u32 = 0;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: u32 = 1;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE: u32 = 2;
pub const VK_ATTACHMENT_STORE_OP_STORE: u32 = 0;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE: u32 = 1;

pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: VkFlags = 0x00000001;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT: VkFlags = 0x00000002;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: VkFlags = 0x00000004;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: VkFlags = 0x00000010;
pub const VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT: VkFlags = 0x00000020;

pub const VK_IMAGE_ASPECT_COLOR_BIT: VkFlags = 0x00000001;
pub const VK_IMAGE_ASPECT_DEPTH_BIT: VkFlags = 0x00000002;

pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: VkFlags = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: VkFlags = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: VkFlags = 0x00000004;
pub const VK_MEMORY_PROPERTY_HOST_CACHED_BIT: VkFlags = 0x00000008;

pub const VK_SHADER_STAGE_VERTEX_BIT: VkFlags = 0x00000001;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: VkFlags = 0x00000010;
pub const VK_SHADER_STAGE_ALL_GRAPHICS: VkFlags = 0x0000001F;

pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT: VkFlags = 0x00000001;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: VkFlags = 0x00000080;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: VkFlags = 0x00000400;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT: VkFlags = 0x00001000;

pub const VK_ACCESS_SHADER_READ_BIT: VkFlags = 0x00000020;
pub const VK_ACCESS_COLOR_ATTACHMENT_READ_BIT: VkFlags = 0x00000080;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: VkFlags = 0x00000100;
pub const VK_ACCESS_TRANSFER_READ_BIT: VkFlags = 0x00000800;
pub const VK_ACCESS_TRANSFER_WRITE_BIT: VkFlags = 0x00001000;

pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;
pub const VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC: u32 = 8;
pub const VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT: VkFlags = 0x00000001;
pub const VK_INDEX_TYPE_UINT16: u32 = 0;
pub const VK_INDEX_TYPE_UINT32: u32 = 1;

pub const VK_CULL_MODE_NONE: VkFlags = 0;
pub const VK_CULL_MODE_FRONT_BIT: VkFlags = 1;
pub const VK_CULL_MODE_BACK_BIT: VkFlags = 2;
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE: u32 = 0;
pub const VK_FRONT_FACE_CLOCKWISE: u32 = 1;

pub const VkOffset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
};

const VkApplicationInfo = extern struct {
    sType: VkStructureType = .application_info,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = "Facet",
    applicationVersion: u32 = 1,
    pEngineName: ?[*:0]const u8 = "Facet",
    engineVersion: u32 = 1,
    apiVersion: u32 = (1 << 22) | (1 << 12), // Vulkan 1.1
};

const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType = .instance_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    pApplicationInfo: ?*const VkApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

const VkQueueFamilyProperties = extern struct {
    queueFlags: VkFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

const VkMemoryType = extern struct {
    propertyFlags: VkFlags,
    heapIndex: u32,
};

const VkMemoryHeap = extern struct {
    size: VkDeviceSize,
    flags: VkFlags,
};

const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType = .device_queue_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    queueFamilyIndex: u32,
    queueCount: u32 = 1,
    pQueuePriorities: [*]const f32,
};

const VkDeviceCreateInfo = extern struct {
    sType: VkStructureType = .device_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    queueCreateInfoCount: u32 = 1,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null,
};

const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType = .command_pool_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0x00000002, // VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
    queueFamilyIndex: u32,
};

const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType = .command_buffer_allocate_info,
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool,
    level: u32 = 0, // PRIMARY
    commandBufferCount: u32 = 1,
};

const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType = .command_buffer_begin_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0x00000001, // ONE_TIME_SUBMIT_BIT
    pInheritanceInfo: ?*const anyopaque = null,
};

const VkSubmitInfo = extern struct {
    sType: VkStructureType = .submit_info,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?*const anyopaque = null,
    pWaitDstStageMask: ?*const u32 = null,
    commandBufferCount: u32 = 1,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?*const anyopaque = null,
};

const VkAttachmentDescription = extern struct {
    flags: VkFlags = 0,
    format: u32,
    samples: u32,
    loadOp: u32,
    storeOp: u32,
    stencilLoadOp: u32 = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    stencilStoreOp: u32 = VK_ATTACHMENT_STORE_OP_DONT_CARE,
    initialLayout: u32 = VK_IMAGE_LAYOUT_UNDEFINED,
    finalLayout: u32,
};

const VkAttachmentReference = extern struct {
    attachment: u32,
    layout: u32,
};

const VkSubpassDescription = extern struct {
    flags: VkFlags = 0,
    pipelineBindPoint: u32 = VK_PIPELINE_BIND_POINT_GRAPHICS,
    inputAttachmentCount: u32 = 0,
    pInputAttachments: ?*const anyopaque = null,
    colorAttachmentCount: u32 = 1,
    pColorAttachments: [*]const VkAttachmentReference,
    pResolveAttachments: ?[*]const VkAttachmentReference = null,
    pDepthStencilAttachment: ?*const VkAttachmentReference = null,
    preserveAttachmentCount: u32 = 0,
    pPreserveAttachments: ?*const u32 = null,
};

const VkSubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: VkFlags,
    dstStageMask: VkFlags,
    srcAccessMask: VkFlags,
    dstAccessMask: VkFlags,
    dependencyFlags: VkFlags = 0,
};

const VkRenderPassCreateInfo = extern struct {
    sType: VkStructureType = .render_pass_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    attachmentCount: u32,
    pAttachments: [*]const VkAttachmentDescription,
    subpassCount: u32 = 1,
    pSubpasses: [*]const VkSubpassDescription,
    dependencyCount: u32 = 0,
    pDependencies: ?[*]const VkSubpassDependency = null,
};

const VkImageCreateInfo = extern struct {
    sType: VkStructureType = .image_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    imageType: u32 = 1, // 2D
    format: u32,
    extent: VkExtent3D,
    mipLevels: u32 = 1,
    arrayLayers: u32 = 1,
    samples: u32,
    tiling: u32 = 0, // OPTIMAL
    usage: VkFlags,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueQueueFamilyIndices: ?*const u32 = null,
    initialLayout: u32 = VK_IMAGE_LAYOUT_UNDEFINED,
};

const VkComponentMapping = extern struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,
};

const VkImageSubresourceRange = extern struct {
    aspectMask: VkFlags,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 1,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

const VkImageViewCreateInfo = extern struct {
    sType: VkStructureType = .image_view_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    image: VkImage,
    viewType: u32 = 1, // 2D
    format: u32,
    components: VkComponentMapping = .{},
    subresourceRange: VkImageSubresourceRange,
};

const VkFramebufferCreateInfo = extern struct {
    sType: VkStructureType = .framebuffer_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    renderPass: VkRenderPass,
    attachmentCount: u32,
    pAttachments: [*]const VkImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

const VkClearValue = extern union {
    color: [4]f32,
    depth_stencil: extern struct {
        depth: f32,
        stencil: u32,
    },
};

const VkRenderPassBeginInfo = extern struct {
    sType: VkStructureType = .render_pass_begin_info,
    pNext: ?*const anyopaque = null,
    renderPass: VkRenderPass,
    framebuffer: VkFramebuffer,
    renderArea: VkRect2D,
    clearValueCount: u32,
    pClearValues: [*]const VkClearValue,
};

const VkImageSubresourceLayers = extern struct {
    aspectMask: VkFlags = VK_IMAGE_ASPECT_COLOR_BIT,
    mipLevel: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

const VkBufferImageCopy = extern struct {
    bufferOffset: VkDeviceSize = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: VkImageSubresourceLayers = .{},
    imageOffset: VkOffset3D = .{},
    imageExtent: VkExtent3D,
};

const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32 = 1,
    stageFlags: VkFlags,
    pImmutableSamplers: ?*const anyopaque = null,
};

const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: VkStructureType = .descriptor_set_layout_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

const VkDescriptorPoolSize = extern struct {
    type: u32,
    descriptorCount: u32,
};

const VkDescriptorPoolCreateInfo = extern struct {
    sType: VkStructureType = .descriptor_pool_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};

const VkDescriptorSetAllocateInfo = extern struct {
    sType: VkStructureType = .descriptor_set_allocate_info,
    pNext: ?*const anyopaque = null,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32 = 1,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};

const VkSamplerCreateInfo = extern struct {
    sType: VkStructureType = .sampler_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    magFilter: u32,
    minFilter: u32,
    mipmapMode: u32 = 0,
    addressModeU: u32 = 2, // CLAMP_TO_EDGE
    addressModeV: u32 = 2, // CLAMP_TO_EDGE
    addressModeW: u32 = 2, // CLAMP_TO_EDGE
    mipLodBias: f32 = 0.0,
    anisotropyEnable: VkBool32 = VK_FALSE,
    maxAnisotropy: f32 = 1.0,
    compareEnable: VkBool32 = VK_FALSE,
    compareOp: u32 = 0,
    minLod: f32 = 0.0,
    maxLod: f32 = 0.0,
    borderColor: u32 = 0,
    unnormalizedCoordinates: VkBool32 = VK_FALSE,
};

const VkDescriptorImageInfo = extern struct {
    sampler: VkSampler,
    imageView: VkImageView,
    imageLayout: u32,
};

const VkImageMemoryBarrier = extern struct {
    sType: VkStructureType = .image_memory_barrier,
    pNext: ?*const anyopaque = null,
    srcAccessMask: VkFlags,
    dstAccessMask: VkFlags,
    oldLayout: u32,
    newLayout: u32,
    srcQueueFamilyIndex: u32 = 0xFFFFFFFF,
    dstQueueFamilyIndex: u32 = 0xFFFFFFFF,
    image: VkImage,
    subresourceRange: VkImageSubresourceRange,
};

const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: VkDeviceSize,
    range: VkDeviceSize,
};

const VkWriteDescriptorSet = extern struct {
    sType: VkStructureType = .write_descriptor_set,
    pNext: ?*const anyopaque = null,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32 = 0,
    descriptorCount: u32 = 1,
    descriptorType: u32,
    pImageInfo: ?*const VkDescriptorImageInfo = null,
    pBufferInfo: ?*const VkDescriptorBufferInfo = null,
    pTexelBufferView: ?*const anyopaque = null,
};

const VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_shader_stage_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    stage: VkFlags,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque = null,
};

const VkVertexInputBindingDescription = extern struct {
    binding: u32 = 0,
    stride: u32,
    inputRate: u32 = 0, // VERTEX
};

const VkVertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32 = 0,
    format: u32,
    offset: u32,
};

const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_vertex_input_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VkVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VkVertexInputAttributeDescription,
};

const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_input_assembly_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    topology: u32 = 3, // TRIANGLE_LIST
    primitiveRestartEnable: VkBool32 = VK_FALSE,
};

const VkPipelineViewportStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_viewport_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    viewportCount: u32 = 1,
    pViewports: ?*const VkViewport = null,
    scissorCount: u32 = 1,
    pScissors: ?*const VkRect2D = null,
};

const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_rasterization_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    depthClampEnable: VkBool32 = VK_FALSE,
    rasterizerDiscardEnable: VkBool32 = VK_FALSE,
    polygonMode: u32 = 0, // FILL
    cullMode: VkFlags = VK_CULL_MODE_BACK_BIT,
    frontFace: u32 = VK_FRONT_FACE_COUNTER_CLOCKWISE,
    depthBiasEnable: VkBool32 = VK_FALSE,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 1.0,
};

const VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_multisample_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    rasterizationSamples: u32 = 4,
    sampleShadingEnable: VkBool32 = VK_FALSE,
    minSampleShading: f32 = 1.0,
    pSampleMask: ?*const u32 = null,
    alphaToCoverageEnable: VkBool32 = VK_FALSE,
    alphaToOneEnable: VkBool32 = VK_FALSE,
};

const VkStencilOpState = extern struct {
    failOp: u32 = 0,
    passOp: u32 = 0,
    depthFailOp: u32 = 0,
    compareOp: u32 = 0,
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};

const VkPipelineDepthStencilStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_depth_stencil_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    depthTestEnable: VkBool32 = VK_TRUE,
    depthWriteEnable: VkBool32 = VK_TRUE,
    depthCompareOp: u32 = 3, // LESS_OR_EQUAL
    depthBoundsTestEnable: VkBool32 = VK_FALSE,
    stencilTestEnable: VkBool32 = VK_FALSE,
    front: VkStencilOpState = .{},
    back: VkStencilOpState = .{},
    minDepthBounds: f32 = 0.0,
    maxDepthBounds: f32 = 1.0,
};

const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: VkBool32 = VK_FALSE,
    srcColorBlendFactor: u32 = 1,
    dstColorBlendFactor: u32 = 0,
    colorBlendOp: u32 = 0,
    srcAlphaBlendFactor: u32 = 1,
    dstAlphaBlendFactor: u32 = 0,
    alphaBlendOp: u32 = 0,
    colorWriteMask: VkFlags = 0xF,
};

const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_color_blend_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    logicOpEnable: VkBool32 = VK_FALSE,
    logicOp: u32 = 0,
    attachmentCount: u32 = 1,
    pAttachments: [*]const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32 = .{ 0, 0, 0, 0 },
};

const VkPipelineDynamicStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_dynamic_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    dynamicStateCount: u32,
    pDynamicStates: [*]const u32,
};

const VkPushConstantRange = extern struct {
    stageFlags: VkFlags,
    offset: u32 = 0,
    size: u32,
};

const VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_layout_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?[*]const VkPushConstantRange = null,
};

const VkGraphicsPipelineCreateInfo = extern struct {
    sType: VkStructureType = .graphics_pipeline_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    stageCount: u32 = 2,
    pStages: [*]const VkPipelineShaderStageCreateInfo,
    pVertexInputState: *const VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: *const VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque = null,
    pViewportState: *const VkPipelineViewportStateCreateInfo,
    pRasterizationState: *const VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: *const VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: *const VkPipelineDepthStencilStateCreateInfo,
    pColorBlendState: *const VkPipelineColorBlendStateCreateInfo,
    pDynamicState: *const VkPipelineDynamicStateCreateInfo,
    layout: VkPipelineLayout,
    renderPass: VkRenderPass,
    subpass: u32 = 0,
    basePipelineHandle: VkPipeline = VK_NULL_HANDLE,
    basePipelineIndex: i32 = -1,
};

const GetInstanceProcAddr = *const fn (?VkInstance, [*:0]const u8) callconv(.c) ?*const anyopaque;

const InstanceProcs = struct {
    DestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,
    EnumeratePhysicalDevices: *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    GetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) callconv(.c) void,
    GetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    CreateDevice: *const fn (VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) callconv(.c) VkResult,
    GetDeviceProcAddr: GetDeviceProcAddr,

    fn load(instance: VkInstance, get_proc: GetInstanceProcAddr) !InstanceProcs {
        var p: InstanceProcs = undefined;
        inline for (@typeInfo(InstanceProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(instance, name) orelse return error.MissingVulkanFunction;
            @field(p, field_name) = @ptrCast(sym);
        }
        return p;
    }
};

/// Full Vulkan device function table available on `VulkanContext.vk`.
pub const ContextProcs = struct {
    DestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    GetDeviceQueue: *const fn (VkDevice, u32, u32, *VkQueue) callconv(.c) void,
    CreateCommandPool: *const fn (VkDevice, *const VkCommandPoolCreateInfo, ?*const anyopaque, *VkCommandPool) callconv(.c) VkResult,
    DestroyCommandPool: *const fn (VkDevice, VkCommandPool, ?*const anyopaque) callconv(.c) void,
    AllocateCommandBuffers: *const fn (VkDevice, *const VkCommandBufferAllocateInfo, [*]VkCommandBuffer) callconv(.c) VkResult,
    ResetCommandBuffer: *const fn (VkCommandBuffer, VkFlags) callconv(.c) VkResult,
    BeginCommandBuffer: *const fn (VkCommandBuffer, *const VkCommandBufferBeginInfo) callconv(.c) VkResult,
    EndCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) VkResult,
    QueueSubmit: *const fn (VkQueue, u32, [*]const VkSubmitInfo, VkFence) callconv(.c) VkResult,
    QueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    DeviceWaitIdle: *const fn (VkDevice) callconv(.c) VkResult,
    CreateRenderPass: *const fn (VkDevice, *const VkRenderPassCreateInfo, ?*const anyopaque, *VkRenderPass) callconv(.c) VkResult,
    DestroyRenderPass: *const fn (VkDevice, VkRenderPass, ?*const anyopaque) callconv(.c) void,
    CreateFramebuffer: *const fn (VkDevice, *const VkFramebufferCreateInfo, ?*const anyopaque, *VkFramebuffer) callconv(.c) VkResult,
    DestroyFramebuffer: *const fn (VkDevice, VkFramebuffer, ?*const anyopaque) callconv(.c) void,
    CreateImage: *const fn (VkDevice, *const VkImageCreateInfo, ?*const anyopaque, *VkImage) callconv(.c) VkResult,
    DestroyImage: *const fn (VkDevice, VkImage, ?*const anyopaque) callconv(.c) void,
    GetImageMemoryRequirements: *const fn (VkDevice, VkImage, *VkMemoryRequirements) callconv(.c) void,
    BindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, VkDeviceSize) callconv(.c) VkResult,
    CreateImageView: *const fn (VkDevice, *const VkImageViewCreateInfo, ?*const anyopaque, *VkImageView) callconv(.c) VkResult,
    DestroyImageView: *const fn (VkDevice, VkImageView, ?*const anyopaque) callconv(.c) void,
    CreateShaderModule: *const fn (VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) callconv(.c) VkResult,
    DestroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void,
    CreateDescriptorSetLayout: *const fn (VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) callconv(.c) VkResult,
    DestroyDescriptorSetLayout: *const fn (VkDevice, VkDescriptorSetLayout, ?*const anyopaque) callconv(.c) void,
    CreateDescriptorPool: *const fn (VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) callconv(.c) VkResult,
    DestroyDescriptorPool: *const fn (VkDevice, VkDescriptorPool, ?*const anyopaque) callconv(.c) void,
    AllocateDescriptorSets: *const fn (VkDevice, *const VkDescriptorSetAllocateInfo, [*]VkDescriptorSet) callconv(.c) VkResult,
    FreeDescriptorSets: *const fn (VkDevice, VkDescriptorPool, u32, [*]const VkDescriptorSet) callconv(.c) VkResult,
    UpdateDescriptorSets: *const fn (VkDevice, u32, [*]const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    CreateSampler: *const fn (VkDevice, *const VkSamplerCreateInfo, ?*const anyopaque, *VkSampler) callconv(.c) VkResult,
    DestroySampler: *const fn (VkDevice, VkSampler, ?*const anyopaque) callconv(.c) void,
    CreatePipelineLayout: *const fn (VkDevice, *const VkPipelineLayoutCreateInfo, ?*const anyopaque, *VkPipelineLayout) callconv(.c) VkResult,
    DestroyPipelineLayout: *const fn (VkDevice, VkPipelineLayout, ?*const anyopaque) callconv(.c) void,
    CreateGraphicsPipelines: *const fn (VkDevice, VkPipelineCache, u32, [*]const VkGraphicsPipelineCreateInfo, ?*const anyopaque, [*]VkPipeline) callconv(.c) VkResult,
    DestroyPipeline: *const fn (VkDevice, VkPipeline, ?*const anyopaque) callconv(.c) void,
    CreateBuffer: *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.c) VkResult,
    DestroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    GetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void,
    AllocateMemory: *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.c) VkResult,
    FreeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void,
    BindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize) callconv(.c) VkResult,
    MapMemory: *const fn (VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, *?*anyopaque) callconv(.c) VkResult,
    UnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    CmdBeginRenderPass: *const fn (VkCommandBuffer, *const VkRenderPassBeginInfo, u32) callconv(.c) void,
    CmdEndRenderPass: *const fn (VkCommandBuffer) callconv(.c) void,
    CmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    CmdSetViewport: *const fn (VkCommandBuffer, u32, u32, [*]const VkViewport) callconv(.c) void,
    CmdSetScissor: *const fn (VkCommandBuffer, u32, u32, [*]const VkRect2D) callconv(.c) void,
    CmdBindVertexBuffers: *const fn (VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const VkDeviceSize) callconv(.c) void,
    CmdBindIndexBuffer: *const fn (VkCommandBuffer, VkBuffer, VkDeviceSize, u32) callconv(.c) void,
    CmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?[*]const u32) callconv(.c) void,
    CmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, VkFlags, u32, u32, *const anyopaque) callconv(.c) void,
    CmdDraw: *const fn (VkCommandBuffer, u32, u32, u32, u32) callconv(.c) void,
    CmdDrawIndexed: *const fn (VkCommandBuffer, u32, u32, u32, i32, u32) callconv(.c) void,
    CmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, [*]const VkBufferImageCopy) callconv(.c) void,
    CmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, [*]const VkBufferImageCopy) callconv(.c) void,
    CmdPipelineBarrier: *const fn (VkCommandBuffer, VkFlags, VkFlags, VkFlags, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?[*]const VkImageMemoryBarrier) callconv(.c) void,

    pub fn load(device: VkDevice, get_proc: GetDeviceProcAddr) !ContextProcs {
        var p: ContextProcs = undefined;
        inline for (@typeInfo(ContextProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(device, name) orelse return error.MissingVulkanFunction;
            @field(p, field_name) = @ptrCast(sym);
        }
        return p;
    }
};

const Owned2DContext = struct {
    const GpuTexture = struct {
        img: VkImage,
        mem: VkDeviceMemory,
        view: VkImageView,
        set: VkDescriptorSet,
    };

    gpa: std.mem.Allocator,
    vk_lib: std.DynLib,
    instance: VkInstance,
    inst_procs: InstanceProcs,
    phys_dev: VkPhysicalDevice,
    mem_props: VkPhysicalDeviceMemoryProperties,
    host_mem_type: u32,
    device: VkDevice,
    vk: ContextProcs,
    queue: VkQueue,
    cmd_pool: VkCommandPool = VK_NULL_HANDLE,
    cmd: VkCommandBuffer = undefined,
    upload_cmd: VkCommandBuffer = undefined,
    render_pass: VkRenderPass = VK_NULL_HANDLE,
    set_layout: VkDescriptorSetLayout = VK_NULL_HANDLE,
    desc_pool: VkDescriptorPool = VK_NULL_HANDLE,
    nearest_sampler: VkSampler = VK_NULL_HANDLE,
    linear_sampler: VkSampler = VK_NULL_HANDLE,
    pipelines: Pipelines = .{},

    atlas_img: VkImage = VK_NULL_HANDLE,
    atlas_mem: VkDeviceMemory = VK_NULL_HANDLE,
    atlas_view: VkImageView = VK_NULL_HANDLE,
    atlas_set: VkDescriptorSet = VK_NULL_HANDLE,
    atlas_initialized: bool = false,

    upload_buf: VkBuffer = VK_NULL_HANDLE,
    upload_mem: VkDeviceMemory = VK_NULL_HANDLE,
    upload_map: []u8 = &.{},

    textures: std.AutoHashMapUnmanaged(u64, GpuTexture) = .empty,

    fb_w: u32 = 0,
    fb_h: u32 = 0,
    color_img: VkImage = VK_NULL_HANDLE,
    color_mem: VkDeviceMemory = VK_NULL_HANDLE,
    color_view: VkImageView = VK_NULL_HANDLE,
    framebuffer: VkFramebuffer = VK_NULL_HANDLE,
    staging_buf: VkBuffer = VK_NULL_HANDLE,
    staging_mem: VkDeviceMemory = VK_NULL_HANDLE,
    staging_map: []u32 = &.{},

    fn create(gpa: std.mem.Allocator) !*Owned2DContext {
        var vk_lib = std.DynLib.open("libvulkan.so.1") catch try std.DynLib.open("libvulkan.so");
        errdefer vk_lib.close();

        const get_inst_proc = vk_lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVkGetInstanceProcAddr;
        const create_instance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult =
            @ptrCast(get_inst_proc(null, "vkCreateInstance") orelse return error.MissingVkCreateInstance);

        const app_info: VkApplicationInfo = .{};
        const inst_info: VkInstanceCreateInfo = .{ .pApplicationInfo = &app_info };
        var instance: VkInstance = undefined;
        if (create_instance(&inst_info, null, &instance) != .success) return error.VkCreateInstanceFailed;

        const inst_procs = try InstanceProcs.load(instance, get_inst_proc);
        errdefer inst_procs.DestroyInstance(instance, null);

        var dev_count: u32 = 0;
        if (inst_procs.EnumeratePhysicalDevices(instance, &dev_count, null) != .success or dev_count == 0) {
            return error.NoVulkanPhysicalDevice;
        }
        var phys_devs: [16]VkPhysicalDevice = undefined;
        var count: u32 = @min(dev_count, phys_devs.len);
        _ = inst_procs.EnumeratePhysicalDevices(instance, &count, &phys_devs);

        var chosen_phys: ?VkPhysicalDevice = null;
        var chosen_qfam: u32 = 0;
        outer: for (phys_devs[0..count]) |pd| {
            var qf_count: u32 = 0;
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
            var qfs: [16]VkQueueFamilyProperties = undefined;
            var qc: u32 = @min(qf_count, qfs.len);
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qc, &qfs);
            for (qfs[0..qc], 0..) |qf, qi| {
                if ((qf.queueFlags & 0x00000001) != 0) {
                    chosen_phys = pd;
                    chosen_qfam = @intCast(qi);
                    break :outer;
                }
            }
        }
        const phys_dev = chosen_phys orelse return error.NoVulkanGraphicsQueue;

        var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
        inst_procs.GetPhysicalDeviceMemoryProperties(phys_dev, &mem_props);

        var host_mem_type: ?u32 = null;
        const req_host = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        for (0..mem_props.memoryTypeCount) |i| {
            if ((mem_props.memoryTypes[i].propertyFlags & req_host) == req_host) {
                host_mem_type = @intCast(i);
                break;
            }
        }
        const host_mt = host_mem_type orelse return error.NoSuitableVulkanMemoryType;

        const prio = [1]f32{1.0};
        const q_info = [1]VkDeviceQueueCreateInfo{.{
            .queueFamilyIndex = chosen_qfam,
            .pQueuePriorities = &prio,
        }};
        const dev_info: VkDeviceCreateInfo = .{ .pQueueCreateInfos = &q_info };
        var device: VkDevice = undefined;
        if (inst_procs.CreateDevice(phys_dev, &dev_info, null, &device) != .success) return error.VkCreateDeviceFailed;

        const vk = try ContextProcs.load(device, inst_procs.GetDeviceProcAddr);
        var queue: VkQueue = undefined;
        vk.GetDeviceQueue(device, chosen_qfam, 0, &queue);

        const self = try gpa.create(Owned2DContext);
        self.* = .{
            .gpa = gpa,
            .vk_lib = vk_lib,
            .instance = instance,
            .inst_procs = inst_procs,
            .phys_dev = phys_dev,
            .mem_props = mem_props,
            .host_mem_type = host_mt,
            .device = device,
            .vk = vk,
            .queue = queue,
        };
        errdefer self.destroy();

        const pool_info: VkCommandPoolCreateInfo = .{ .queueFamilyIndex = chosen_qfam };
        if (self.vk.CreateCommandPool(device, &pool_info, null, &self.cmd_pool) != .success) return error.VkCreateCommandPoolFailed;

        const cb_info: VkCommandBufferAllocateInfo = .{ .commandPool = self.cmd_pool, .commandBufferCount = 2 };
        var cmds: [2]VkCommandBuffer = undefined;
        if (self.vk.AllocateCommandBuffers(device, &cb_info, &cmds) != .success) return error.VkAllocateCommandBufferFailed;
        self.cmd = cmds[0];
        self.upload_cmd = cmds[1];

        const attachments = [1]VkAttachmentDescription{.{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .samples = 1,
            .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        }};
        const color_ref = [1]VkAttachmentReference{.{
            .attachment = 0,
            .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        }};
        const subpass = [1]VkSubpassDescription{.{
            .pColorAttachments = &color_ref,
        }};
        const rp_info: VkRenderPassCreateInfo = .{
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .pSubpasses = &subpass,
        };
        if (self.vk.CreateRenderPass(device, &rp_info, null, &self.render_pass) != .success) return error.VkCreateRenderPassFailed;

        const bindings = [1]VkDescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        }};
        const dsl_info: VkDescriptorSetLayoutCreateInfo = .{
            .bindingCount = 1,
            .pBindings = &bindings,
        };
        if (self.vk.CreateDescriptorSetLayout(device, &dsl_info, null, &self.set_layout) != .success) return error.VkCreateDescriptorSetLayoutFailed;

        const pool_sizes = [1]VkDescriptorPoolSize{.{
            .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 256,
        }};
        const dp_info: VkDescriptorPoolCreateInfo = .{
            .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 256,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_sizes,
        };
        if (self.vk.CreateDescriptorPool(device, &dp_info, null, &self.desc_pool) != .success) return error.VkCreateDescriptorPoolFailed;

        const nearest_info: VkSamplerCreateInfo = .{ .magFilter = 0, .minFilter = 0 };
        if (self.vk.CreateSampler(device, &nearest_info, null, &self.nearest_sampler) != .success) return error.VkCreateSamplerFailed;

        const linear_info: VkSamplerCreateInfo = .{ .magFilter = 1, .minFilter = 1 };
        if (self.vk.CreateSampler(device, &linear_info, null, &self.linear_sampler) != .success) return error.VkCreateSamplerFailed;

        return self;
    }

    fn initPipelines(self: *Owned2DContext, mods: ShaderModules) !void {
        const set_layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const pl_info: VkPipelineLayoutCreateInfo = .{
            .setLayoutCount = 1,
            .pSetLayouts = &set_layouts,
        };
        if (self.vk.CreatePipelineLayout(self.device, &pl_info, null, &self.pipelines.layout) != .success) {
            return error.VkCreatePipelineLayoutFailed;
        }
        self.pipelines.shape = try self.create2DPipeline(mods.shape, shaders.shape_layout, true);
        self.pipelines.solid = try self.create2DPipeline(mods.solid, shaders.solid_layout, true);
        self.pipelines.@"opaque" = try self.create2DPipeline(mods.solid, shaders.solid_layout, false);
        self.pipelines.text = try self.create2DPipeline(mods.text, shaders.text_layout, true);
        self.pipelines.image = try self.create2DPipeline(mods.image, shaders.text_layout, true);
    }

    fn create2DPipeline(self: *Owned2DContext, shader_mod: VkShaderModule, layout: shaders.Layout, blend: bool) !VkPipeline {
        const stages = [2]VkPipelineShaderStageCreateInfo{
            .{ .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader_mod, .pName = "vertex" },
            .{ .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader_mod, .pName = "fragment" },
        };
        const binding = [1]VkVertexInputBindingDescription{.{ .stride = layout.vertex_stride }};
        var attrs: [8]VkVertexInputAttributeDescription = undefined;
        const attr_count = @min(layout.attributes.len, attrs.len);
        for (layout.attributes[0..attr_count], attrs[0..attr_count]) |a, *out| {
            out.* = .{
                .location = a.location,
                .format = switch (a.components) {
                    1 => VK_FORMAT_R32_SFLOAT,
                    2 => VK_FORMAT_R32G32_SFLOAT,
                    3 => VK_FORMAT_R32G32B32_SFLOAT,
                    else => VK_FORMAT_R32G32B32A32_SFLOAT,
                },
                .offset = a.offset,
            };
        }
        const vertex_input: VkPipelineVertexInputStateCreateInfo = .{
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding,
            .vertexAttributeDescriptionCount = @intCast(attr_count),
            .pVertexAttributeDescriptions = &attrs,
        };
        const input_assembly: VkPipelineInputAssemblyStateCreateInfo = .{};
        const viewport_state: VkPipelineViewportStateCreateInfo = .{};
        const raster: VkPipelineRasterizationStateCreateInfo = .{
            .cullMode = VK_CULL_MODE_NONE,
            .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        };
        const multisample: VkPipelineMultisampleStateCreateInfo = .{
            .rasterizationSamples = 1,
        };
        const depth_stencil: VkPipelineDepthStencilStateCreateInfo = .{
            .depthTestEnable = VK_FALSE,
            .depthWriteEnable = VK_FALSE,
        };
        const blend_att = [1]VkPipelineColorBlendAttachmentState{if (blend) .{
            .blendEnable = VK_TRUE,
            .srcColorBlendFactor = 6, // VK_BLEND_FACTOR_SRC_ALPHA
            .dstColorBlendFactor = 7, // VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            .colorBlendOp = 0, // VK_BLEND_OP_ADD
            .srcAlphaBlendFactor = 1, // VK_BLEND_FACTOR_ONE
            .dstAlphaBlendFactor = 7, // VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            .alphaBlendOp = 0, // VK_BLEND_OP_ADD
            .colorWriteMask = 0xF,
        } else .{
            .blendEnable = VK_FALSE,
            .colorWriteMask = 0xF,
        }};
        const color_blend: VkPipelineColorBlendStateCreateInfo = .{ .pAttachments = &blend_att };
        const dyn_states = [2]u32{ 0, 1 }; // VIEWPORT, SCISSOR
        const dynamic_state: VkPipelineDynamicStateCreateInfo = .{
            .dynamicStateCount = dyn_states.len,
            .pDynamicStates = &dyn_states,
        };
        const gp_info = [1]VkGraphicsPipelineCreateInfo{.{
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blend,
            .pDynamicState = &dynamic_state,
            .layout = self.pipelines.layout,
            .renderPass = self.render_pass,
        }};
        var out_pipe: [1]VkPipeline = undefined;
        if (self.vk.CreateGraphicsPipelines(self.device, VK_NULL_HANDLE, 1, &gp_info, null, &out_pipe) != .success) {
            return error.VkCreateGraphicsPipelineFailed;
        }
        return out_pipe[0];
    }

    fn destroy(self: *Owned2DContext) void {
        _ = self.vk.DeviceWaitIdle(self.device);
        self.destroyTarget();
        if (self.upload_map.len > 0) self.vk.UnmapMemory(self.device, self.upload_mem);
        if (self.upload_buf != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, self.upload_buf, null);
        if (self.upload_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.upload_mem, null);

        var it = self.textures.valueIterator();
        while (it.next()) |t| {
            if (t.view != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, t.view, null);
            if (t.img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, t.img, null);
            if (t.mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, t.mem, null);
        }
        self.textures.deinit(self.gpa);

        if (self.atlas_view != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, self.atlas_view, null);
        if (self.atlas_img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, self.atlas_img, null);
        if (self.atlas_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.atlas_mem, null);

        for ([_]VkPipeline{
            self.pipelines.shape,
            self.pipelines.solid,
            self.pipelines.@"opaque",
            self.pipelines.text,
            self.pipelines.image,
        }) |p| {
            if (p != VK_NULL_HANDLE) self.vk.DestroyPipeline(self.device, p, null);
        }
        if (self.pipelines.layout != VK_NULL_HANDLE) self.vk.DestroyPipelineLayout(self.device, self.pipelines.layout, null);
        if (self.nearest_sampler != VK_NULL_HANDLE) self.vk.DestroySampler(self.device, self.nearest_sampler, null);
        if (self.linear_sampler != VK_NULL_HANDLE) self.vk.DestroySampler(self.device, self.linear_sampler, null);
        if (self.desc_pool != VK_NULL_HANDLE) self.vk.DestroyDescriptorPool(self.device, self.desc_pool, null);
        if (self.set_layout != VK_NULL_HANDLE) self.vk.DestroyDescriptorSetLayout(self.device, self.set_layout, null);
        if (self.render_pass != VK_NULL_HANDLE) self.vk.DestroyRenderPass(self.device, self.render_pass, null);
        if (self.cmd_pool != VK_NULL_HANDLE) self.vk.DestroyCommandPool(self.device, self.cmd_pool, null);
        self.vk.DestroyDevice(self.device, null);
        self.inst_procs.DestroyInstance(self.instance, null);
        self.vk_lib.close();
        self.gpa.destroy(self);
    }

    fn findMemoryType(self: *const Owned2DContext, type_bits: u32, req_flags: VkFlags) !u32 {
        for (0..self.mem_props.memoryTypeCount) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if ((type_bits & bit) != 0 and (self.mem_props.memoryTypes[i].propertyFlags & req_flags) == req_flags) {
                return @intCast(i);
            }
        }
        return error.NoSuitableVulkanMemoryType;
    }

    fn ensureUploadBuf(self: *Owned2DContext, min_bytes: usize) !void {
        if (self.upload_map.len >= min_bytes) return;
        if (self.upload_map.len > 0) {
            self.vk.UnmapMemory(self.device, self.upload_mem);
            self.upload_map = &.{};
        }
        if (self.upload_buf != VK_NULL_HANDLE) {
            self.vk.DestroyBuffer(self.device, self.upload_buf, null);
            self.upload_buf = VK_NULL_HANDLE;
        }
        if (self.upload_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.upload_mem, null);
            self.upload_mem = VK_NULL_HANDLE;
        }
        const cap = std.mem.alignForward(usize, min_bytes, 64 * 1024);
        const buf_info: VkBufferCreateInfo = .{
            .size = cap,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.upload_buf) != .success) return error.VkCreateBufferFailed;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.upload_buf, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, cap),
            .memoryTypeIndex = mem_type,
        };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.upload_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.upload_buf, self.upload_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.upload_mem, 0, cap, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
        self.upload_map = @as([*]u8, @ptrCast(ptr.?))[0..cap];
    }

    fn textureHooks(self: *Owned2DContext) TextureHooks {
        return .{
            .ctx = self,
            .uploadAtlas = uploadAtlasHook,
            .acquireImage = acquireImageHook,
            .releaseImage = releaseImageHook,
        };
    }

    fn uploadAtlasHook(raw: ?*anyopaque, pixels: []const u8, width: u32, height: u32, y0: u32, y1: u32) anyerror!VkDescriptorSet {
        const self: *Owned2DContext = @ptrCast(@alignCast(raw.?));
        if (self.atlas_img == VK_NULL_HANDLE) {
            const img_info: VkImageCreateInfo = .{
                .format = VK_FORMAT_R8_UNORM,
                .extent = .{ .width = width, .height = height },
                .samples = 1,
                .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            };
            if (self.vk.CreateImage(self.device, &img_info, null, &self.atlas_img) != .success) return error.VkCreateImageFailed;
            var req: VkMemoryRequirements = undefined;
            self.vk.GetImageMemoryRequirements(self.device, self.atlas_img, &req);
            const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
            if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.atlas_mem) != .success) return error.VkAllocateMemoryFailed;
            if (self.vk.BindImageMemory(self.device, self.atlas_img, self.atlas_mem, 0) != .success) return error.VkBindImageMemoryFailed;

            const view_info: VkImageViewCreateInfo = .{
                .image = self.atlas_img,
                .format = VK_FORMAT_R8_UNORM,
                .components = .{
                    .r = VK_COMPONENT_SWIZZLE_R,
                    .g = VK_COMPONENT_SWIZZLE_R,
                    .b = VK_COMPONENT_SWIZZLE_R,
                    .a = VK_COMPONENT_SWIZZLE_R,
                },
                .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            };
            if (self.vk.CreateImageView(self.device, &view_info, null, &self.atlas_view) != .success) return error.VkCreateImageViewFailed;

            const layouts = [1]VkDescriptorSetLayout{self.set_layout};
            const dsa_info: VkDescriptorSetAllocateInfo = .{
                .descriptorPool = self.desc_pool,
                .pSetLayouts = &layouts,
            };
            var sets: [1]VkDescriptorSet = undefined;
            if (self.vk.AllocateDescriptorSets(self.device, &dsa_info, &sets) != .success) return error.VkAllocateDescriptorSetsFailed;
            self.atlas_set = sets[0];

            const img_desc: VkDescriptorImageInfo = .{
                .sampler = self.nearest_sampler,
                .imageView = self.atlas_view,
                .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            const write = [1]VkWriteDescriptorSet{.{
                .dstSet = self.atlas_set,
                .dstBinding = 0,
                .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &img_desc,
            }};
            self.vk.UpdateDescriptorSets(self.device, 1, &write, 0, null);
            self.atlas_initialized = false;
        }

        if (y1 > y0) {
            const row_h = y1 - y0;
            const byte_len = @as(usize, width) * row_h;
            try self.ensureUploadBuf(byte_len);
            const src = pixels[@as(usize, y0) * width ..][0..byte_len];
            @memcpy(self.upload_map[0..byte_len], src);

            _ = self.vk.ResetCommandBuffer(self.upload_cmd, 0);
            const begin_info: VkCommandBufferBeginInfo = .{};
            if (self.vk.BeginCommandBuffer(self.upload_cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

            const to_dst = [1]VkImageMemoryBarrier{.{
                .srcAccessMask = if (self.atlas_initialized) VK_ACCESS_SHADER_READ_BIT else 0,
                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout = if (self.atlas_initialized) VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .image = self.atlas_img,
                .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            }};
            self.vk.CmdPipelineBarrier(
                self.upload_cmd,
                if (self.atlas_initialized) VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT else VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT,
                0,
                0,
                null,
                0,
                null,
                1,
                &to_dst,
            );

            const region = [1]VkBufferImageCopy{.{
                .bufferOffset = 0,
                .bufferRowLength = width,
                .bufferImageHeight = row_h,
                .imageOffset = .{ .x = 0, .y = @intCast(y0), .z = 0 },
                .imageExtent = .{ .width = width, .height = row_h, .depth = 1 },
            }};
            self.vk.CmdCopyBufferToImage(self.upload_cmd, self.upload_buf, self.atlas_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

            const to_read = [1]VkImageMemoryBarrier{.{
                .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
                .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .image = self.atlas_img,
                .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            }};
            self.vk.CmdPipelineBarrier(
                self.upload_cmd,
                VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                0,
                0,
                null,
                0,
                null,
                1,
                &to_read,
            );

            if (self.vk.EndCommandBuffer(self.upload_cmd) != .success) return error.VkEndCommandBufferFailed;
            const cmds = [1]VkCommandBuffer{self.upload_cmd};
            const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
            if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
            _ = self.vk.QueueWaitIdle(self.queue);
            self.atlas_initialized = true;
        }
        return self.atlas_set;
    }

    fn acquireImageHook(raw: ?*anyopaque, id: u64, pixels: []const u32, width: u32, height: u32) anyerror!VkDescriptorSet {
        const self: *Owned2DContext = @ptrCast(@alignCast(raw.?));
        if (self.textures.get(id)) |existing| return existing.set;

        const img_info: VkImageCreateInfo = .{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = width, .height = height },
            .samples = 1,
            .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        };
        var img: VkImage = VK_NULL_HANDLE;
        if (self.vk.CreateImage(self.device, &img_info, null, &img) != .success) return error.VkCreateImageFailed;
        errdefer self.vk.DestroyImage(self.device, img, null);

        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, img, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer self.vk.FreeMemory(self.device, mem, null);

        if (self.vk.BindImageMemory(self.device, img, mem, 0) != .success) return error.VkBindImageMemoryFailed;

        const view_info: VkImageViewCreateInfo = .{
            .image = img,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        };
        var view: VkImageView = VK_NULL_HANDLE;
        if (self.vk.CreateImageView(self.device, &view_info, null, &view) != .success) return error.VkCreateImageViewFailed;
        errdefer self.vk.DestroyImageView(self.device, view, null);

        const layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const dsa_info: VkDescriptorSetAllocateInfo = .{
            .descriptorPool = self.desc_pool,
            .pSetLayouts = &layouts,
        };
        var sets: [1]VkDescriptorSet = undefined;
        if (self.vk.AllocateDescriptorSets(self.device, &dsa_info, &sets) != .success) return error.VkAllocateDescriptorSetsFailed;
        const set = sets[0];

        const img_desc: VkDescriptorImageInfo = .{
            .sampler = self.linear_sampler,
            .imageView = view,
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = [1]VkWriteDescriptorSet{.{
            .dstSet = set,
            .dstBinding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &img_desc,
        }};
        self.vk.UpdateDescriptorSets(self.device, 1, &write, 0, null);

        const bytes = std.mem.sliceAsBytes(pixels);
        try self.ensureUploadBuf(bytes.len);
        @memcpy(self.upload_map[0..bytes.len], bytes);

        _ = self.vk.ResetCommandBuffer(self.upload_cmd, 0);
        const begin_info: VkCommandBufferBeginInfo = .{};
        if (self.vk.BeginCommandBuffer(self.upload_cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

        const to_dst = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.upload_cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_dst);

        const region = [1]VkBufferImageCopy{.{
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        }};
        self.vk.CmdCopyBufferToImage(self.upload_cmd, self.upload_buf, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        const to_read = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .image = img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.upload_cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &to_read);

        if (self.vk.EndCommandBuffer(self.upload_cmd) != .success) return error.VkEndCommandBufferFailed;
        const cmds = [1]VkCommandBuffer{self.upload_cmd};
        const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
        _ = self.vk.QueueWaitIdle(self.queue);

        try self.textures.put(self.gpa, id, .{ .img = img, .mem = mem, .view = view, .set = set });
        return set;
    }

    fn releaseImageHook(raw: ?*anyopaque, id: u64) void {
        const self: *Owned2DContext = @ptrCast(@alignCast(raw.?));
        if (self.textures.fetchRemove(id)) |kv| {
            _ = self.vk.DeviceWaitIdle(self.device);
            const t = kv.value;
            if (t.view != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, t.view, null);
            if (t.img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, t.img, null);
            if (t.mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, t.mem, null);
            if (t.set != VK_NULL_HANDLE) {
                const sets = [1]VkDescriptorSet{t.set};
                _ = self.vk.FreeDescriptorSets(self.device, self.desc_pool, 1, &sets);
            }
        }
    }

    fn destroyTarget(self: *Owned2DContext) void {
        if (self.staging_map.len > 0) {
            self.vk.UnmapMemory(self.device, self.staging_mem);
            self.staging_map = &.{};
        }
        if (self.staging_buf != VK_NULL_HANDLE) {
            self.vk.DestroyBuffer(self.device, self.staging_buf, null);
            self.staging_buf = VK_NULL_HANDLE;
        }
        if (self.staging_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.staging_mem, null);
            self.staging_mem = VK_NULL_HANDLE;
        }
        if (self.framebuffer != VK_NULL_HANDLE) {
            self.vk.DestroyFramebuffer(self.device, self.framebuffer, null);
            self.framebuffer = VK_NULL_HANDLE;
        }
        if (self.color_view != VK_NULL_HANDLE) {
            self.vk.DestroyImageView(self.device, self.color_view, null);
            self.color_view = VK_NULL_HANDLE;
        }
        if (self.color_img != VK_NULL_HANDLE) {
            self.vk.DestroyImage(self.device, self.color_img, null);
            self.color_img = VK_NULL_HANDLE;
        }
        if (self.color_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.color_mem, null);
            self.color_mem = VK_NULL_HANDLE;
        }
        self.fb_w = 0;
        self.fb_h = 0;
    }

    fn ensureTarget(self: *Owned2DContext, w: u32, h: u32) !void {
        if (self.fb_w == w and self.fb_h == h and self.framebuffer != VK_NULL_HANDLE) return;
        self.destroyTarget();
        errdefer self.destroyTarget();

        const img_info: VkImageCreateInfo = .{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = w, .height = h },
            .samples = 1,
            .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        };
        if (self.vk.CreateImage(self.device, &img_info, null, &self.color_img) != .success) return error.VkCreateImageFailed;

        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, self.color_img, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.color_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindImageMemory(self.device, self.color_img, self.color_mem, 0) != .success) return error.VkBindImageMemoryFailed;

        const view_info: VkImageViewCreateInfo = .{
            .image = self.color_img,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        };
        if (self.vk.CreateImageView(self.device, &view_info, null, &self.color_view) != .success) return error.VkCreateImageViewFailed;

        const views = [1]VkImageView{self.color_view};
        const fb_info: VkFramebufferCreateInfo = .{
            .renderPass = self.render_pass,
            .attachmentCount = 1,
            .pAttachments = &views,
            .width = w,
            .height = h,
        };
        if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &self.framebuffer) != .success) return error.VkCreateFramebufferFailed;

        const pixel_count = @as(usize, w) * h;
        const byte_size: VkDeviceSize = pixel_count * 4;
        const buf_info: VkBufferCreateInfo = .{
            .size = byte_size,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.staging_buf) != .success) return error.VkCreateBufferFailed;
        var buf_req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.staging_buf, &buf_req);
        const buf_mt = try readbackMemoryType(self, buf_req.memoryTypeBits);
        const buf_alloc: VkMemoryAllocateInfo = .{
            .allocationSize = @max(buf_req.size, byte_size),
            .memoryTypeIndex = buf_mt,
        };
        if (self.vk.AllocateMemory(self.device, &buf_alloc, null, &self.staging_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.staging_buf, self.staging_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.staging_mem, 0, byte_size, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
        self.staging_map = @as([*]u32, @ptrCast(@alignCast(ptr.?)))[0..pixel_count];

        self.fb_w = w;
        self.fb_h = h;
    }

    fn renderCanvasToImage(self: *Owned2DContext, r: *VulkanRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
        const w = target.width;
        const h = target.height;
        try self.ensureTarget(w, h);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = w, .height = h };
        const fallback_regions = [1]Viewport{full_vp};
        const regions = if (damage) |d| (if (d.len <= 16) d else &fallback_regions) else &fallback_regions;
        const stride = target.rowStride();

        var copy_regions: [16]VkBufferImageCopy = undefined;
        var copy_count: u32 = 0;
        for (regions) |reg| {
            const sc = full_vp.intersect(reg) orelse continue;
            const sx: usize = @intCast(sc.x);
            const sy: usize = @intCast(sc.y);
            for (0..sc.height) |row| {
                const src = target.pixels[(sy + row) * stride + sx ..][0..sc.width];
                @memcpy(self.staging_map[(sy + row) * w + sx ..][0..sc.width], src);
            }
            copy_regions[copy_count] = .{
                .bufferOffset = (@as(VkDeviceSize, @intCast(sy)) * w + @as(VkDeviceSize, @intCast(sx))) * 4,
                .bufferRowLength = w,
                .bufferImageHeight = h,
                .imageOffset = .{ .x = sc.x, .y = sc.y, .z = 0 },
                .imageExtent = .{ .width = sc.width, .height = sc.height, .depth = 1 },
            };
            copy_count += 1;
        }
        if (copy_count == 0) return;

        _ = self.vk.ResetCommandBuffer(self.cmd, 0);
        const begin_info: VkCommandBufferBeginInfo = .{};
        if (self.vk.BeginCommandBuffer(self.cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

        const to_dst = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = self.color_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_dst);

        self.vk.CmdCopyBufferToImage(self.cmd, self.staging_buf, self.color_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, copy_count, &copy_regions);

        const to_color = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .image = self.color_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &to_color);

        const dummy_clear = [1]VkClearValue{.{ .color = .{ 0, 0, 0, 0 } }};
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = w, .height = h },
            },
            .clearValueCount = 0,
            .pClearValues = &dummy_clear,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);

        const cmd_target: Target = .{ .cmd = self.cmd, .width = w, .height = h, .flip_viewport_y = true };
        try r.recordTarget(c, &cmd_target, damage);

        self.vk.CmdEndRenderPass(self.cmd);

        const to_readback = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .image = self.color_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_readback);

        self.vk.CmdCopyImageToBuffer(self.cmd, self.color_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.staging_buf, copy_count, &copy_regions);

        if (self.vk.EndCommandBuffer(self.cmd) != .success) return error.VkEndCommandBufferFailed;
        const cmds = [1]VkCommandBuffer{self.cmd};
        const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
        _ = self.vk.QueueWaitIdle(self.queue);

        for (regions) |reg| {
            const sc = full_vp.intersect(reg) orelse continue;
            const dx: usize = @intCast(sc.x);
            const dy: usize = @intCast(sc.y);
            for (0..sc.height) |row| {
                const src = self.staging_map[(dy + row) * w + dx ..][0..sc.width];
                @memcpy(target.pixels[(dy + row) * stride + dx ..][0..sc.width], src);
            }
        }
    }
};

/// A host-visible memory type for a buffer the CPU reads back from: a
/// cached one if there is one, since reading uncached memory is many times
/// slower (10 ms instead of 0.25 ms for a 1.3 megapixel frame).
fn readbackMemoryType(ctx: anytype, type_bits: u32) !u32 {
    const host = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    return ctx.findMemoryType(type_bits, host | VK_MEMORY_PROPERTY_HOST_CACHED_BIT) catch ctx.findMemoryType(type_bits, host);
}

/// Managed offscreen Vulkan 1.1+ context with configurable MSAA (`1`, `2`, `4`, `8` samples)
/// render passes, dynamic uniform buffer (`gpu.uniforms`), pipeline builder, and
/// automatic readback for `VulkanArea`.
pub const OffscreenContext = struct {
    pub const sample_counts = [4]u32{ 1, 2, 4, 8 };

    pub fn sampleIndex(samples: u8) u2 {
        return switch (samples) {
            0, 1 => 0,
            2, 3 => 1,
            4...7 => 2,
            else => 3,
        };
    }

    pub const Buffer = struct {
        buffer: VkBuffer = VK_NULL_HANDLE,
        memory: VkDeviceMemory = VK_NULL_HANDLE,
        size: VkDeviceSize = 0,
    };

    pub const Pipeline = struct {
        layout: VkPipelineLayout = VK_NULL_HANDLE,
        pipelines: [sample_counts.len]VkPipeline = @splat(VK_NULL_HANDLE),
    };

    pub const PipelineDesc = struct {
        /// Combined SPIR-V module containing `vertex` and `fragment` entry points.
        shader_spv: []align(4) const u8,
        vertex_stride: u32,
        attributes: []const shaders.Attribute,
        push_constant_size: u32 = 0,
        cull_mode: VkFlags = VK_CULL_MODE_BACK_BIT,
        front_face: u32 = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        depth_test: bool = true,
    };

    const ubo_slot_size: usize = 256;
    const ubo_max_draws: usize = 64;
    const ubo_total_size: usize = ubo_slot_size * ubo_max_draws;

    gpa: std.mem.Allocator,
    vk_lib: std.DynLib,
    instance: VkInstance,
    inst_procs: InstanceProcs,
    phys_dev: VkPhysicalDevice,
    mem_props: VkPhysicalDeviceMemoryProperties,
    device: VkDevice,
    vk: ContextProcs,
    queue: VkQueue,
    cmd_pool: VkCommandPool = VK_NULL_HANDLE,
    cmd: VkCommandBuffer = undefined,
    render_passes: [sample_counts.len]VkRenderPass = @splat(VK_NULL_HANDLE),
    set_layout: VkDescriptorSetLayout = VK_NULL_HANDLE,
    desc_pool: VkDescriptorPool = VK_NULL_HANDLE,
    desc_set: VkDescriptorSet = VK_NULL_HANDLE,
    ubo_buf: VkBuffer = VK_NULL_HANDLE,
    ubo_mem: VkDeviceMemory = VK_NULL_HANDLE,
    ubo_map: []u8 = &.{},
    ubo_cursor: u32 = 0,
    active_layout: VkPipelineLayout = VK_NULL_HANDLE,

    width: u32 = 0,
    height: u32 = 0,
    fb_w: u32 = 0,
    fb_h: u32 = 0,
    fb_sample_idx: u2 = 2,
    msaa_color_img: VkImage = VK_NULL_HANDLE,
    msaa_color_mem: VkDeviceMemory = VK_NULL_HANDLE,
    msaa_color_view: VkImageView = VK_NULL_HANDLE,
    msaa_depth_img: VkImage = VK_NULL_HANDLE,
    msaa_depth_mem: VkDeviceMemory = VK_NULL_HANDLE,
    msaa_depth_view: VkImageView = VK_NULL_HANDLE,
    resolve_img: VkImage = VK_NULL_HANDLE,
    resolve_mem: VkDeviceMemory = VK_NULL_HANDLE,
    resolve_view: VkImageView = VK_NULL_HANDLE,
    framebuffer: VkFramebuffer = VK_NULL_HANDLE,
    readback_buf: VkBuffer = VK_NULL_HANDLE,
    readback_mem: VkDeviceMemory = VK_NULL_HANDLE,
    readback_map: []u32 = &.{},

    pub fn init(gpa: std.mem.Allocator) !OffscreenContext {
        var vk_lib = std.DynLib.open("libvulkan.so.1") catch try std.DynLib.open("libvulkan.so");
        errdefer vk_lib.close();

        const get_inst_proc = vk_lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVkGetInstanceProcAddr;
        const create_instance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult =
            @ptrCast(get_inst_proc(null, "vkCreateInstance") orelse return error.MissingVkCreateInstance);

        const app_info: VkApplicationInfo = .{};
        const inst_info: VkInstanceCreateInfo = .{ .pApplicationInfo = &app_info };
        var instance: VkInstance = undefined;
        if (create_instance(&inst_info, null, &instance) != .success) return error.VkCreateInstanceFailed;

        const inst_procs = try InstanceProcs.load(instance, get_inst_proc);
        errdefer inst_procs.DestroyInstance(instance, null);

        var dev_count: u32 = 0;
        if (inst_procs.EnumeratePhysicalDevices(instance, &dev_count, null) != .success or dev_count == 0) {
            return error.NoVulkanPhysicalDevice;
        }
        var phys_devs: [16]VkPhysicalDevice = undefined;
        var count: u32 = @min(dev_count, phys_devs.len);
        _ = inst_procs.EnumeratePhysicalDevices(instance, &count, &phys_devs);

        var chosen_phys: ?VkPhysicalDevice = null;
        var chosen_qfam: u32 = 0;
        outer: for (phys_devs[0..count]) |pd| {
            var qf_count: u32 = 0;
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
            var qfs: [16]VkQueueFamilyProperties = undefined;
            var qc: u32 = @min(qf_count, qfs.len);
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qc, &qfs);
            for (qfs[0..qc], 0..) |qf, qi| {
                if ((qf.queueFlags & 0x00000001) != 0) { // VK_QUEUE_GRAPHICS_BIT
                    chosen_phys = pd;
                    chosen_qfam = @intCast(qi);
                    break :outer;
                }
            }
        }
        const phys_dev = chosen_phys orelse return error.NoVulkanGraphicsQueue;

        var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
        inst_procs.GetPhysicalDeviceMemoryProperties(phys_dev, &mem_props);

        const prio = [1]f32{1.0};
        const q_info = [1]VkDeviceQueueCreateInfo{.{
            .queueFamilyIndex = chosen_qfam,
            .pQueuePriorities = &prio,
        }};
        const dev_info: VkDeviceCreateInfo = .{ .pQueueCreateInfos = &q_info };
        var device: VkDevice = undefined;
        if (inst_procs.CreateDevice(phys_dev, &dev_info, null, &device) != .success) return error.VkCreateDeviceFailed;

        const vk = try ContextProcs.load(device, inst_procs.GetDeviceProcAddr);
        var queue: VkQueue = undefined;
        vk.GetDeviceQueue(device, chosen_qfam, 0, &queue);

        var self: OffscreenContext = .{
            .gpa = gpa,
            .vk_lib = vk_lib,
            .instance = instance,
            .inst_procs = inst_procs,
            .phys_dev = phys_dev,
            .mem_props = mem_props,
            .device = device,
            .vk = vk,
            .queue = queue,
        };
        errdefer self.deinit();

        const pool_info: VkCommandPoolCreateInfo = .{ .queueFamilyIndex = chosen_qfam };
        if (self.vk.CreateCommandPool(device, &pool_info, null, &self.cmd_pool) != .success) return error.VkCreateCommandPoolFailed;

        const cb_info: VkCommandBufferAllocateInfo = .{ .commandPool = self.cmd_pool };
        var cmds: [1]VkCommandBuffer = undefined;
        if (self.vk.AllocateCommandBuffers(device, &cb_info, &cmds) != .success) return error.VkAllocateCommandBufferFailed;
        self.cmd = cmds[0];

        // Create render passes for 1× (direct) and 2×/4×/8× MSAA (resolving to 1× B8G8R8A8_UNORM in TRANSFER_SRC_OPTIMAL)
        for (sample_counts, 0..) |sc, idx| {
            if (sc == 1) {
                const attachments = [2]VkAttachmentDescription{
                    .{
                        .format = VK_FORMAT_B8G8R8A8_UNORM,
                        .samples = 1,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    },
                    .{
                        .format = VK_FORMAT_D32_SFLOAT,
                        .samples = 1,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                        .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    },
                };
                const color_ref = [1]VkAttachmentReference{.{ .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }};
                const depth_ref: VkAttachmentReference = .{ .attachment = 1, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
                const subpass = [1]VkSubpassDescription{.{
                    .pColorAttachments = &color_ref,
                    .pResolveAttachments = null,
                    .pDepthStencilAttachment = &depth_ref,
                }};
                const rp_info: VkRenderPassCreateInfo = .{
                    .attachmentCount = attachments.len,
                    .pAttachments = &attachments,
                    .pSubpasses = &subpass,
                };
                if (self.vk.CreateRenderPass(device, &rp_info, null, &self.render_passes[idx]) != .success) return error.VkCreateRenderPassFailed;
            } else {
                const attachments = [3]VkAttachmentDescription{
                    .{
                        .format = VK_FORMAT_B8G8R8A8_UNORM,
                        .samples = sc,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                        .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    },
                    .{
                        .format = VK_FORMAT_D32_SFLOAT,
                        .samples = sc,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                        .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    },
                    .{
                        .format = VK_FORMAT_B8G8R8A8_UNORM,
                        .samples = 1,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    },
                };
                const color_ref = [1]VkAttachmentReference{.{ .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }};
                const depth_ref: VkAttachmentReference = .{ .attachment = 1, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
                const resolve_ref = [1]VkAttachmentReference{.{ .attachment = 2, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }};
                const subpass = [1]VkSubpassDescription{.{
                    .pColorAttachments = &color_ref,
                    .pResolveAttachments = &resolve_ref,
                    .pDepthStencilAttachment = &depth_ref,
                }};
                const rp_info: VkRenderPassCreateInfo = .{
                    .attachmentCount = attachments.len,
                    .pAttachments = &attachments,
                    .pSubpasses = &subpass,
                };
                if (self.vk.CreateRenderPass(device, &rp_info, null, &self.render_passes[idx]) != .success) return error.VkCreateRenderPassFailed;
            }
        }

        // Descriptor set layout and dynamic uniform buffer for `gpu.uniforms(T)` at set=0, binding=0
        const bindings = [1]VkDescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
        }};
        const dsl_info: VkDescriptorSetLayoutCreateInfo = .{
            .bindingCount = 1,
            .pBindings = &bindings,
        };
        if (self.vk.CreateDescriptorSetLayout(device, &dsl_info, null, &self.set_layout) != .success) return error.VkCreateDescriptorSetLayoutFailed;

        const pool_sizes = [1]VkDescriptorPoolSize{.{
            .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 1,
        }};
        const dp_info: VkDescriptorPoolCreateInfo = .{
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_sizes,
        };
        if (self.vk.CreateDescriptorPool(device, &dp_info, null, &self.desc_pool) != .success) return error.VkCreateDescriptorPoolFailed;

        const layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const dsa_info: VkDescriptorSetAllocateInfo = .{
            .descriptorPool = self.desc_pool,
            .pSetLayouts = &layouts,
        };
        var sets: [1]VkDescriptorSet = undefined;
        if (self.vk.AllocateDescriptorSets(device, &dsa_info, &sets) != .success) return error.VkAllocateDescriptorSetsFailed;
        self.desc_set = sets[0];

        const ubo_info: VkBufferCreateInfo = .{
            .size = ubo_total_size,
            .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        };
        if (self.vk.CreateBuffer(device, &ubo_info, null, &self.ubo_buf) != .success) return error.VkCreateBufferFailed;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(device, self.ubo_buf, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, ubo_total_size),
            .memoryTypeIndex = mem_type,
        };
        if (self.vk.AllocateMemory(device, &alloc_info, null, &self.ubo_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(device, self.ubo_buf, self.ubo_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ubo_ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(device, self.ubo_mem, 0, ubo_total_size, 0, &ubo_ptr) != .success or ubo_ptr == null) return error.VkMapMemoryFailed;
        self.ubo_map = @as([*]u8, @ptrCast(ubo_ptr.?))[0..ubo_total_size];

        const buf_desc: VkDescriptorBufferInfo = .{
            .buffer = self.ubo_buf,
            .offset = 0,
            .range = ubo_slot_size,
        };
        const write = [1]VkWriteDescriptorSet{.{
            .dstSet = self.desc_set,
            .dstBinding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .pBufferInfo = &buf_desc,
        }};
        self.vk.UpdateDescriptorSets(device, 1, &write, 0, null);

        return self;
    }

    pub fn deinit(self: *OffscreenContext) void {
        _ = self.vk.DeviceWaitIdle(self.device);
        self.destroyTargets();
        if (self.ubo_map.len > 0) self.vk.UnmapMemory(self.device, self.ubo_mem);
        if (self.ubo_buf != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, self.ubo_buf, null);
        if (self.ubo_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.ubo_mem, null);
        if (self.desc_pool != VK_NULL_HANDLE) self.vk.DestroyDescriptorPool(self.device, self.desc_pool, null);
        if (self.set_layout != VK_NULL_HANDLE) self.vk.DestroyDescriptorSetLayout(self.device, self.set_layout, null);
        for (self.render_passes) |rp| {
            if (rp != VK_NULL_HANDLE) self.vk.DestroyRenderPass(self.device, rp, null);
        }
        if (self.cmd_pool != VK_NULL_HANDLE) self.vk.DestroyCommandPool(self.device, self.cmd_pool, null);
        self.vk.DestroyDevice(self.device, null);
        self.inst_procs.DestroyInstance(self.instance, null);
        self.vk_lib.close();
    }

    pub fn aspect(self: *const OffscreenContext) f32 {
        if (self.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    fn findMemoryType(self: *const OffscreenContext, type_bits: u32, req_flags: VkFlags) !u32 {
        for (0..self.mem_props.memoryTypeCount) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if ((type_bits & bit) != 0 and (self.mem_props.memoryTypes[i].propertyFlags & req_flags) == req_flags) {
                return @intCast(i);
            }
        }
        return error.NoSuitableVulkanMemoryType;
    }

    pub fn createBuffer(self: *const OffscreenContext, usage: VkBufferUsageFlags, bytes: []const u8) !Buffer {
        const size: VkDeviceSize = @max(bytes.len, 16);
        const buf_info: VkBufferCreateInfo = .{ .size = size, .usage = usage };
        var buf: VkBuffer = VK_NULL_HANDLE;
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &buf) != .success) return error.VkCreateBufferFailed;
        errdefer self.vk.DestroyBuffer(self.device, buf, null);

        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, buf, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, size),
            .memoryTypeIndex = mem_type,
        };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer self.vk.FreeMemory(self.device, mem, null);

        if (self.vk.BindBufferMemory(self.device, buf, mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        if (bytes.len > 0) {
            var ptr: ?*anyopaque = null;
            if (self.vk.MapMemory(self.device, mem, 0, size, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
            @memcpy(@as([*]u8, @ptrCast(ptr.?))[0..bytes.len], bytes);
            self.vk.UnmapMemory(self.device, mem);
        }
        return .{ .buffer = buf, .memory = mem, .size = size };
    }

    pub fn createVertexBuffer(self: *const OffscreenContext, comptime T: type, items: []const T) !Buffer {
        return self.createBuffer(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, std.mem.sliceAsBytes(items));
    }

    pub fn createIndexBuffer(self: *const OffscreenContext, indices: []const u16) !Buffer {
        return self.createBuffer(VK_BUFFER_USAGE_INDEX_BUFFER_BIT, std.mem.sliceAsBytes(indices));
    }

    pub fn destroyBuffer(self: *const OffscreenContext, buf: Buffer) void {
        if (buf.buffer != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, buf.buffer, null);
        if (buf.memory != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, buf.memory, null);
    }

    pub fn createPipeline(self: *const OffscreenContext, desc: PipelineDesc) !Pipeline {
        const sm_info: VkShaderModuleCreateInfo = .{
            .codeSize = desc.shader_spv.len,
            .pCode = @ptrCast(desc.shader_spv.ptr),
        };
        var shader_mod: VkShaderModule = VK_NULL_HANDLE;
        if (self.vk.CreateShaderModule(self.device, &sm_info, null, &shader_mod) != .success) return error.VkCreateShaderModuleFailed;
        defer self.vk.DestroyShaderModule(self.device, shader_mod, null);

        const set_layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const pc_range = [1]VkPushConstantRange{.{
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
            .size = desc.push_constant_size,
        }};
        const pl_info: VkPipelineLayoutCreateInfo = .{
            .setLayoutCount = 1,
            .pSetLayouts = &set_layouts,
            .pushConstantRangeCount = if (desc.push_constant_size > 0) 1 else 0,
            .pPushConstantRanges = if (desc.push_constant_size > 0) &pc_range else null,
        };
        var layout: VkPipelineLayout = VK_NULL_HANDLE;
        if (self.vk.CreatePipelineLayout(self.device, &pl_info, null, &layout) != .success) return error.VkCreatePipelineLayoutFailed;

        var p: Pipeline = .{ .layout = layout };
        errdefer self.destroyPipeline(p);

        const stages = [2]VkPipelineShaderStageCreateInfo{
            .{ .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader_mod, .pName = "vertex" },
            .{ .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader_mod, .pName = "fragment" },
        };

        const binding = [1]VkVertexInputBindingDescription{.{ .stride = desc.vertex_stride }};
        var attrs: [8]VkVertexInputAttributeDescription = undefined;
        const attr_count = @min(desc.attributes.len, attrs.len);
        for (desc.attributes[0..attr_count], attrs[0..attr_count]) |a, *out| {
            out.* = .{
                .location = a.location,
                .format = switch (a.components) {
                    1 => VK_FORMAT_R32_SFLOAT,
                    2 => VK_FORMAT_R32G32_SFLOAT,
                    3 => VK_FORMAT_R32G32B32_SFLOAT,
                    else => VK_FORMAT_R32G32B32A32_SFLOAT,
                },
                .offset = a.offset,
            };
        }
        const vertex_input: VkPipelineVertexInputStateCreateInfo = .{
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding,
            .vertexAttributeDescriptionCount = @intCast(attr_count),
            .pVertexAttributeDescriptions = &attrs,
        };
        const input_assembly: VkPipelineInputAssemblyStateCreateInfo = .{};
        const viewport_state: VkPipelineViewportStateCreateInfo = .{};
        const raster: VkPipelineRasterizationStateCreateInfo = .{
            .cullMode = desc.cull_mode,
            .frontFace = desc.front_face,
        };
        const depth_stencil: VkPipelineDepthStencilStateCreateInfo = .{
            .depthTestEnable = if (desc.depth_test) VK_TRUE else VK_FALSE,
            .depthWriteEnable = if (desc.depth_test) VK_TRUE else VK_FALSE,
        };
        const blend_att = [1]VkPipelineColorBlendAttachmentState{.{}};
        const color_blend: VkPipelineColorBlendStateCreateInfo = .{ .pAttachments = &blend_att };
        const dyn_states = [2]u32{ 0, 1 }; // VIEWPORT, SCISSOR
        const dynamic_state: VkPipelineDynamicStateCreateInfo = .{
            .dynamicStateCount = dyn_states.len,
            .pDynamicStates = &dyn_states,
        };

        for (sample_counts, 0..) |sc, idx| {
            const multisample: VkPipelineMultisampleStateCreateInfo = .{
                .rasterizationSamples = sc,
            };
            const gp_info = [1]VkGraphicsPipelineCreateInfo{.{
                .pStages = &stages,
                .pVertexInputState = &vertex_input,
                .pInputAssemblyState = &input_assembly,
                .pViewportState = &viewport_state,
                .pRasterizationState = &raster,
                .pMultisampleState = &multisample,
                .pDepthStencilState = &depth_stencil,
                .pColorBlendState = &color_blend,
                .pDynamicState = &dynamic_state,
                .layout = layout,
                .renderPass = self.render_passes[idx],
            }};
            var out_pipe: [1]VkPipeline = undefined;
            if (self.vk.CreateGraphicsPipelines(self.device, VK_NULL_HANDLE, 1, &gp_info, null, &out_pipe) != .success) {
                return error.VkCreateGraphicsPipelineFailed;
            }
            p.pipelines[idx] = out_pipe[0];
        }
        return p;
    }

    pub fn destroyPipeline(self: *const OffscreenContext, p: Pipeline) void {
        for (p.pipelines) |pipe| {
            if (pipe != VK_NULL_HANDLE) self.vk.DestroyPipeline(self.device, pipe, null);
        }
        if (p.layout != VK_NULL_HANDLE) self.vk.DestroyPipelineLayout(self.device, p.layout, null);
    }

    pub fn bindPipeline(self: *OffscreenContext, p: Pipeline) void {
        self.active_layout = p.layout;
        self.vk.CmdBindPipeline(self.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p.pipelines[self.fb_sample_idx]);
    }

    pub fn setUniforms(self: *OffscreenContext, comptime T: type, value: *const T) void {
        std.debug.assert(@sizeOf(T) <= ubo_slot_size);
        if (self.ubo_cursor >= ubo_max_draws) return;
        const offset: u32 = self.ubo_cursor * @as(u32, @intCast(ubo_slot_size));
        self.ubo_cursor += 1;
        @memcpy(self.ubo_map[offset..][0..@sizeOf(T)], std.mem.asBytes(value));
        const sets = [1]VkDescriptorSet{self.desc_set};
        const dyn_offsets = [1]u32{offset};
        self.vk.CmdBindDescriptorSets(
            self.cmd,
            VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.active_layout,
            0,
            1,
            &sets,
            1,
            &dyn_offsets,
        );
    }

    pub fn bindVertexBuffer(self: *const OffscreenContext, buf: Buffer) void {
        const bufs = [1]VkBuffer{buf.buffer};
        const offs = [1]VkDeviceSize{0};
        self.vk.CmdBindVertexBuffers(self.cmd, 0, 1, &bufs, &offs);
    }

    pub fn bindIndexBuffer16(self: *const OffscreenContext, buf: Buffer) void {
        self.vk.CmdBindIndexBuffer(self.cmd, buf.buffer, 0, VK_INDEX_TYPE_UINT16);
    }

    pub fn drawIndexed(self: *const OffscreenContext, index_count: u32) void {
        self.vk.CmdDrawIndexed(self.cmd, index_count, 1, 0, 0, 0);
    }

    fn createAttachmentImage(
        self: *const OffscreenContext,
        w: u32,
        h: u32,
        format: u32,
        samples: u32,
        usage: VkFlags,
        aspect_mask: VkFlags,
    ) !struct { img: VkImage, mem: VkDeviceMemory, view: VkImageView } {
        const img_info: VkImageCreateInfo = .{
            .format = format,
            .extent = .{ .width = w, .height = h },
            .samples = samples,
            .usage = usage,
        };
        var img: VkImage = VK_NULL_HANDLE;
        if (self.vk.CreateImage(self.device, &img_info, null, &img) != .success) return error.VkCreateImageFailed;
        errdefer self.vk.DestroyImage(self.device, img, null);

        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, img, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = req.size,
            .memoryTypeIndex = mem_type,
        };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer self.vk.FreeMemory(self.device, mem, null);

        if (self.vk.BindImageMemory(self.device, img, mem, 0) != .success) return error.VkBindImageMemoryFailed;

        const view_info: VkImageViewCreateInfo = .{
            .image = img,
            .format = format,
            .subresourceRange = .{ .aspectMask = aspect_mask },
        };
        var view: VkImageView = VK_NULL_HANDLE;
        if (self.vk.CreateImageView(self.device, &view_info, null, &view) != .success) return error.VkCreateImageViewFailed;

        return .{ .img = img, .mem = mem, .view = view };
    }

    fn destroyTargets(self: *OffscreenContext) void {
        if (self.readback_map.len > 0) {
            self.vk.UnmapMemory(self.device, self.readback_mem);
            self.readback_map = &.{};
        }
        if (self.readback_buf != VK_NULL_HANDLE) {
            self.vk.DestroyBuffer(self.device, self.readback_buf, null);
            self.readback_buf = VK_NULL_HANDLE;
        }
        if (self.readback_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.readback_mem, null);
            self.readback_mem = VK_NULL_HANDLE;
        }
        if (self.framebuffer != VK_NULL_HANDLE) {
            self.vk.DestroyFramebuffer(self.device, self.framebuffer, null);
            self.framebuffer = VK_NULL_HANDLE;
        }
        for ([_]VkImageView{ self.msaa_color_view, self.msaa_depth_view, self.resolve_view }) |v| {
            if (v != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, v, null);
        }
        for ([_]VkImage{ self.msaa_color_img, self.msaa_depth_img, self.resolve_img }) |img| {
            if (img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, img, null);
        }
        for ([_]VkDeviceMemory{ self.msaa_color_mem, self.msaa_depth_mem, self.resolve_mem }) |m| {
            if (m != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, m, null);
        }
        self.msaa_color_view = VK_NULL_HANDLE;
        self.msaa_depth_view = VK_NULL_HANDLE;
        self.resolve_view = VK_NULL_HANDLE;
        self.msaa_color_img = VK_NULL_HANDLE;
        self.msaa_depth_img = VK_NULL_HANDLE;
        self.resolve_img = VK_NULL_HANDLE;
        self.msaa_color_mem = VK_NULL_HANDLE;
        self.msaa_depth_mem = VK_NULL_HANDLE;
        self.resolve_mem = VK_NULL_HANDLE;
        self.fb_w = 0;
        self.fb_h = 0;
    }

    fn ensureTargets(self: *OffscreenContext, w: u32, h: u32, samples: u8) !void {
        const s_idx = sampleIndex(samples);
        const sc = sample_counts[s_idx];
        if (self.fb_w == w and self.fb_h == h and self.fb_sample_idx == s_idx and self.framebuffer != VK_NULL_HANDLE) return;
        self.destroyTargets();
        errdefer self.destroyTargets();

        const res_c = try self.createAttachmentImage(w, h, VK_FORMAT_B8G8R8A8_UNORM, 1, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
        self.resolve_img = res_c.img;
        self.resolve_mem = res_c.mem;
        self.resolve_view = res_c.view;

        const msaa_d = try self.createAttachmentImage(w, h, VK_FORMAT_D32_SFLOAT, sc, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_IMAGE_ASPECT_DEPTH_BIT);
        self.msaa_depth_img = msaa_d.img;
        self.msaa_depth_mem = msaa_d.mem;
        self.msaa_depth_view = msaa_d.view;

        if (sc == 1) {
            const views = [2]VkImageView{ self.resolve_view, self.msaa_depth_view };
            const fb_info: VkFramebufferCreateInfo = .{
                .renderPass = self.render_passes[s_idx],
                .attachmentCount = views.len,
                .pAttachments = &views,
                .width = w,
                .height = h,
            };
            if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &self.framebuffer) != .success) return error.VkCreateFramebufferFailed;
        } else {
            const msaa_c = try self.createAttachmentImage(w, h, VK_FORMAT_B8G8R8A8_UNORM, sc, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
            self.msaa_color_img = msaa_c.img;
            self.msaa_color_mem = msaa_c.mem;
            self.msaa_color_view = msaa_c.view;

            const views = [3]VkImageView{ self.msaa_color_view, self.msaa_depth_view, self.resolve_view };
            const fb_info: VkFramebufferCreateInfo = .{
                .renderPass = self.render_passes[s_idx],
                .attachmentCount = views.len,
                .pAttachments = &views,
                .width = w,
                .height = h,
            };
            if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &self.framebuffer) != .success) return error.VkCreateFramebufferFailed;
        }

        const pixel_count = @as(usize, w) * h;
        const byte_size: VkDeviceSize = pixel_count * 4;
        const buf_info: VkBufferCreateInfo = .{
            .size = byte_size,
            .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.readback_buf) != .success) return error.VkCreateBufferFailed;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.readback_buf, &req);
        const mem_type = try readbackMemoryType(self, req.memoryTypeBits);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, byte_size),
            .memoryTypeIndex = mem_type,
        };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.readback_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.readback_buf, self.readback_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.readback_mem, 0, byte_size, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
        self.readback_map = @as([*]u32, @ptrCast(@alignCast(ptr.?)))[0..pixel_count];

        self.fb_w = w;
        self.fb_h = h;
        self.fb_sample_idx = s_idx;
    }

    pub fn renderToImage(
        self: *OffscreenContext,
        target: *software.Image,
        area: GpuArea,
        clear_color: ?Color,
        samples: u8,
        user_ctx: anytype,
        comptime render_fn: anytype,
    ) !void {
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return;
        const sc = if (area.scissor) |s| vp.intersect(s) orelse return else vp;

        try self.ensureTargets(vp.width, vp.height, samples);
        self.width = vp.width;
        self.height = vp.height;
        self.ubo_cursor = 0;

        _ = self.vk.ResetCommandBuffer(self.cmd, 0);
        const begin_info: VkCommandBufferBeginInfo = .{};
        if (self.vk.BeginCommandBuffer(self.cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

        const bg = clear_color orelse Color.argb(0xff000000);
        const clears = [2]VkClearValue{
            .{ .color = .{ bg.r, bg.g, bg.b, bg.a } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.render_passes[self.fb_sample_idx],
            .framebuffer = self.framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = vp.width, .height = vp.height },
            },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);

        const wf: f32 = @floatFromInt(vp.width);
        const hf: f32 = @floatFromInt(vp.height);
        // Negative viewport height (Vulkan 1.1+) makes clip-space +Y point up, matching OpenGL.
        const vk_vp = [1]VkViewport{.{ .x = 0, .y = hf, .width = wf, .height = -hf, .minDepth = 0.0, .maxDepth = 1.0 }};
        const vk_sc = [1]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = vp.width, .height = vp.height } }};
        self.vk.CmdSetViewport(self.cmd, 0, 1, &vk_vp);
        self.vk.CmdSetScissor(self.cmd, 0, 1, &vk_sc);

        try render_fn(user_ctx, self);

        self.vk.CmdEndRenderPass(self.cmd);

        const copy_region = [1]VkBufferImageCopy{.{
            .imageExtent = .{ .width = vp.width, .height = vp.height, .depth = 1 },
        }};
        self.vk.CmdCopyImageToBuffer(
            self.cmd,
            self.resolve_img,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.readback_buf,
            1,
            &copy_region,
        );

        if (self.vk.EndCommandBuffer(self.cmd) != .success) return error.VkEndCommandBufferFailed;

        const cmds = [1]VkCommandBuffer{self.cmd};
        const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
        _ = self.vk.QueueWaitIdle(self.queue);

        const local_x: usize = @intCast(@max(sc.x - vp.x, 0));
        const local_y: usize = @intCast(@max(sc.y - vp.y, 0));
        const dst_stride = target.rowStride();
        for (0..sc.height) |row| {
            const dst_y: usize = @intCast(sc.y + @as(i32, @intCast(row)));
            if (dst_y >= target.height) break;
            const dst_x: usize = @intCast(@max(sc.x, 0));
            const copy_w = @min(@as(usize, sc.width), target.width -| dst_x);
            const src_row = self.readback_map[(local_y + row) * vp.width + local_x ..][0..copy_w];
            @memcpy(target.pixels[dst_y * dst_stride + dst_x ..][0..copy_w], src_row);
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

    const pixels = try std.testing.allocator.alloc(u32, 200 * 100);
    defer std.testing.allocator.free(pixels);
    var target: software.Image = .{ .pixels = pixels, .width = 200, .height = 100 };
    target.clear(0xff000000);
    try vk_renderer.renderer().draw(&c, &target);
    try std.testing.expectEqual(@as(usize, 3), MockVk.draws);
    try std.testing.expectEqual(@as(i32, 12), MockVk.last_scissor.offset.x);
    try std.testing.expectEqual(@as(i32, 18), MockVk.last_scissor.offset.y);
    try std.testing.expectEqual(@as(u32, 60), MockVk.last_scissor.extent.width);
    try std.testing.expectEqual(@as(u32, 40), MockVk.last_scissor.extent.height);
}

test "VulkanRenderer.initDefault renders 2D Canvas shapes and images into software.Image" {
    var vk_renderer = VulkanRenderer.initDefault(std.testing.allocator) catch return;
    defer vk_renderer.deinit();

    const w: u32 = 100;
    const h: u32 = 80;
    const pixels = try std.testing.allocator.alloc(u32, w * h);
    defer std.testing.allocator.free(pixels);
    var img: software.Image = .{ .pixels = pixels, .width = w, .height = h };
    img.clear(0xff112233);

    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(w, h);
    c.fillRoundedRect(.{ .x = 10, .y = 10, .w = 40, .h = 30 }, .all(4), .rgb(0xff0000));
    const tex_px = [_]u32{ 0xff00ff00, 0xff00ff00, 0xff00ff00, 0xff00ff00 };
    const pic = canvas_mod.Image.init(&tex_px, 2, 2);
    c.drawImage(&pic, .{ .x = 60, .y = 10, .w = 20, .h = 20 }, 1.0);

    try vk_renderer.renderer().draw(&c, &img);
    try std.testing.expectEqual(@as(u32, 0xff112233), img.pixels[2 * w + 2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), img.pixels[25 * w + 30]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), img.pixels[20 * w + 70]);
}
