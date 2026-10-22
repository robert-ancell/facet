//! VulkanArea: a widget that manages an offscreen Vulkan 1.1+ context,
//! 4× MSAA render pass, dynamic uniform buffer, and automatic resolve/readback
//! so an application only needs to write its `Scene` (`State.init`,
//! `State.deinit`, and `render`).

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const decorated = @import("decorated.zig");
const Painter = @import("painter.zig").Painter;

const Size = geometry.Size;
const Point = geometry.Point;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Event = widget.Event;
const PointerCursor = widget.PointerCursor;
const ValueCallback = widget.ValueCallback;
const Border = decorated.Border;

/// A widget that draws a scene of the app's with a Vulkan context into the area it takes.
pub fn VulkanArea(comptime Scene: type) type {
    return struct {
        const Self = @This();
        const HasState = @hasDecl(Scene, "State");

        /// The app's scene: what draws (its `render`), and its state (see the top of this file).
        scene: Scene,
        /// How many samples per pixel are used to smooth edges (multisampling).
        samples: u8 = 4,
        /// The colour the area is cleared to before the scene is drawn (the
        /// theme's surface container if not given).
        clear_color: ?gfx.Color = null,
        /// The corners' radii of the area.
        radius: gfx.CornerRadii = .all(12),
        /// An outline around the area (none, if null).
        border: ?Border = null,
        /// Called with how far the pointer moved while it is dragged over the
        /// area; without it the area is not draggable.
        on_drag: ?ValueCallback(Point) = null,
        /// The narrowest it can be, in pixels.
        min_width: f32 = 280,
        /// The shortest it can be, in pixels.
        min_height: f32 = 260,
        /// Identifies what is drawn: the same key as in the last frame means
        /// the same picture, so it is not drawn again. Without one, the scene's
        /// bytes, the clear colour and the samples decide.
        key: ?u64 = null,
        /// A widget drawn over the area.
        child: ?Widget = null,

        pub const State = struct {
            gpa: ?std.mem.Allocator = null,
            vk_ctx: ?gfx.VulkanContext = null,
            scene_state: if (HasState) ?Scene.State else void = if (HasState) null else {},
            init_failed: bool = false,
            dragging: bool = false,
            last_pos: Point = .{ 0, 0 },

            pub fn deinit(st: *State) void {
                if (st.vk_ctx) |*ctx| {
                    _ = ctx.vk.DeviceWaitIdle(ctx.device);
                    if (HasState) {
                        if (st.scene_state) |*ss| {
                            if (@hasDecl(Scene.State, "deinit")) {
                                const params = @typeInfo(@TypeOf(Scene.State.deinit)).@"fn".param_types;
                                if (params.len == 3) {
                                    ss.deinit(ctx, st.gpa.?);
                                } else if (params.len == 2) {
                                    ss.deinit(ctx);
                                } else {
                                    ss.deinit();
                                }
                            }
                        }
                    }
                    ctx.deinit();
                    st.vk_ctx = null;
                }
            }
        };

        const DrawPayload = struct {
            vk_ctx: *gfx.VulkanContext,
            scene: Scene,
            scene_state: if (HasState) *Scene.State else void,
            clear_color: gfx.Color,
            samples: u8,
        };

        pub fn layout(self: *const Self, n: *Node, c: Constraints) Size {
            const size = c.constrain(.{
                .w = if (c.boundedWidth()) c.max_w else @max(self.min_width, 460),
                .h = if (c.boundedHeight()) c.max_h else @max(self.min_height, 380),
            });
            for (n.children.items) |ch| _ = ch.layout(.tight(size));
            return size;
        }

        pub fn minSize(self: *const Self, _: *Node, c: Constraints) Size {
            return c.constrain(.{ .w = self.min_width, .h = self.min_height });
        }

        pub fn cursor(self: *const Self, n: *Node, _: Point) ?PointerCursor {
            if (self.on_drag == null) return null;
            return if (n.state(State).dragging) .grabbing else .grab;
        }

        pub fn event(self: *const Self, n: *Node, e: Event) bool {
            const cb = self.on_drag orelse return false;
            const st = n.state(State);
            switch (e) {
                .press => |pr| {
                    if (pr.button != .left) return false;
                    st.dragging = true;
                    st.last_pos = pr.pos;
                    n.ui.needs_frame = true;
                    return true;
                },
                .motion => |pos| if (st.dragging) {
                    const dx = pos[0] - st.last_pos[0];
                    const dy = pos[1] - st.last_pos[1];
                    st.last_pos = pos;
                    cb.call(.{ dx, dy });
                    n.ui.needs_frame = true;
                    return true;
                },
                .release => if (st.dragging) {
                    st.dragging = false;
                    n.ui.needs_frame = true;
                    return true;
                },
                else => {},
            }
            return false;
        }

        pub fn paint(self: *const Self, n: *Node, p: *Painter) void {
            const st = n.state(State);
            const t = n.theme();
            const bg = self.clear_color orelse t.surface_container;

            if (!st.init_failed and st.vk_ctx == null) {
                st.gpa = n.ui.gpa;
                // On the UI's Vulkan renderer's device if it has one, so that
                // the scene is drawn straight into its frames; or else on a
                // device of its own, and copied in.
                const shared: ?gfx.VulkanContext = if (sharedDevice(n)) |dev| gfx.VulkanContext.initShared(n.ui.gpa, dev) catch null else null;
                if (if (shared) |ctx| ctx else gfx.VulkanContext.init(n.ui.gpa)) |ctx| {
                    st.vk_ctx = ctx;
                    if (HasState) {
                        const params = @typeInfo(@TypeOf(Scene.State.init)).@"fn".param_types;
                        const init_res = if (params.len == 2)
                            Scene.State.init(&st.vk_ctx.?, n.ui.gpa)
                        else
                            Scene.State.init(&st.vk_ctx.?);
                        if (init_res) |ss| {
                            st.scene_state = ss;
                        } else |_| {
                            st.vk_ctx.?.deinit();
                            st.vk_ctx = null;
                            st.init_failed = true;
                        }
                    }
                } else |_| {
                    st.init_failed = true;
                }
            }

            if (st.vk_ctx == null) {
                const c = p.canvas();
                c.fillRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, self.radius, bg);
                if (self.border) |b| {
                    c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = n.size.w - 1, .h = n.size.h - 1 }, self.radius, b.width, b.color);
                }
                return;
            }

            const payload = n.ui.arena().create(DrawPayload) catch return;
            payload.* = .{
                .vk_ctx = &st.vk_ctx.?,
                .scene = self.scene,
                .scene_state = if (HasState) &st.scene_state.? else {},
                .clear_color = bg,
                .samples = self.samples,
            };

            const draw_key = self.key orelse blk: {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&self.scene));
                hasher.update(std.mem.asBytes(&bg));
                hasher.update(&.{self.samples});
                break :blk hasher.final();
            };

            // The scene is drawn over a clear and copied in, replacing every
            // pixel of the box.
            p.gpuWithDirect(.{ .key = draw_key, .fills = true }, payload, drawGpu, drawDirect);

            if (self.border) |b| {
                const c = p.canvas();
                c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = n.size.w - 1, .h = n.size.h - 1 }, self.radius, b.width, b.color);
            }
        }

        /// The device of the UI's renderer, if it is the Vulkan one.
        fn sharedDevice(n: *Node) ?gfx.vulkan.SharedDevice {
            const vr = &(n.ui.shared.vulkan_renderer orelse return null);
            const r = n.ui.shared.renderer orelse return null;
            if (r.ptr != @as(*anyopaque, @ptrCast(vr))) return null;
            return vr.sharedDevice();
        }

        fn drawDirect(payload: *const DrawPayload, backend: gfx.RenderBackend, frame: *const anyopaque, area: gfx.GpuArea) anyerror!bool {
            if (backend != .vulkan) return false;
            const f: *const gfx.vulkan.DirectFrame = @ptrCast(@alignCast(frame));
            return payload.vk_ctx.renderToFrame(f, area, payload.clear_color, payload.samples, payload, renderScene);
        }

        fn drawGpu(payload: *const DrawPayload, target: *gfx.software.Image, area: gfx.GpuArea) anyerror!void {
            try payload.vk_ctx.renderToImage(target, area, payload.clear_color, payload.samples, payload, renderScene);
        }

        fn renderScene(payload: *const DrawPayload, ctx: *gfx.VulkanContext) anyerror!void {
            if (HasState) {
                try payload.scene.render(payload.scene_state, ctx);
            } else {
                try payload.scene.render(ctx);
            }
        }
    };
}
