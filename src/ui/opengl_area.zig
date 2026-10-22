//! OpenGlArea: a widget that manages an offscreen OpenGL Core context,
//! configurable MSAA color/depth framebuffer, and automatic resolve/readback so an
//! application only needs to write its `Scene` (`State.init`, `State.deinit`,
//! and `render`).

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

/// A widget that draws a scene of the app's with an OpenGL context into the area it takes.
pub fn OpenGlArea(comptime Scene: type) type {
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
            gl_ctx: ?gfx.OpenGlContext = null,
            scene_state: if (HasState) ?Scene.State else void = if (HasState) null else {},
            init_failed: bool = false,
            dragging: bool = false,
            last_pos: Point = .{ 0, 0 },

            pub fn supportsSpirv(st: *const State) bool {
                return if (st.gl_ctx) |*ctx| ctx.supportsSpirv() else false;
            }

            pub fn deinit(st: *State) void {
                if (st.gl_ctx) |*ctx| {
                    ctx.makeCurrent();
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
                    st.gl_ctx = null;
                }
            }
        };

        const DrawPayload = struct {
            gl_ctx: *gfx.OpenGlContext,
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

            if (!st.init_failed and st.gl_ctx == null) {
                st.gpa = n.ui.gpa;
                if (gfx.OpenGlContext.init(n.ui.gpa)) |ctx| {
                    st.gl_ctx = ctx;
                    if (HasState) {
                        const params = @typeInfo(@TypeOf(Scene.State.init)).@"fn".param_types;
                        const init_res = if (params.len == 2)
                            Scene.State.init(&st.gl_ctx.?, n.ui.gpa)
                        else
                            Scene.State.init(&st.gl_ctx.?);
                        if (init_res) |ss| {
                            st.scene_state = ss;
                        } else |_| {
                            st.gl_ctx.?.deinit();
                            st.gl_ctx = null;
                            st.init_failed = true;
                        }
                    }
                } else |_| {
                    st.init_failed = true;
                }
            }

            if (st.gl_ctx == null) {
                const c = p.canvas();
                c.fillRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, self.radius, bg);
                if (self.border) |b| {
                    c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = n.size.w - 1, .h = n.size.h - 1 }, self.radius, b.width, b.color);
                }
                return;
            }

            const payload = n.ui.arena().create(DrawPayload) catch return;
            payload.* = .{
                .gl_ctx = &st.gl_ctx.?,
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

        /// Drawn on the GPU into a frame the Vulkan renderer draws straight
        /// into the window: the scene is exported as a dmabuf and copied in
        /// on the GPU, with no copy through the CPU.
        fn drawDirect(payload: *const DrawPayload, backend: gfx.RenderBackend, frame: *const anyopaque, area: gfx.GpuArea) anyerror!bool {
            if (backend != .vulkan) return false;
            const f: *const gfx.vulkan.DirectFrame = @ptrCast(@alignCast(frame));
            const picture = (try payload.gl_ctx.renderToDmabuf(area, payload.clear_color, payload.samples, payload, renderScene)) orelse return false;
            return f.copy_dmabuf(f.copy_ctx, f, &picture, area);
        }

        fn drawGpu(payload: *const DrawPayload, target: *gfx.software.Image, area: gfx.GpuArea) anyerror!void {
            try payload.gl_ctx.renderToImage(target, area, payload.clear_color, payload.samples, payload, renderScene);
        }

        fn renderScene(payload: *const DrawPayload, ctx: *gfx.OpenGlContext) anyerror!void {
            if (HasState) {
                try payload.scene.render(payload.scene_state, ctx);
            } else {
                try payload.scene.render(ctx);
            }
        }
    };
}
