//! MetalArea: a widget that draws a 3D scene with Metal (on macOS): a
//! multisampled colour and depth target, resolved and drawn straight into
//! the Metal renderer's frame on its GPU (or else copied in through the
//! CPU), so an application only needs to write its `Scene` (`State.init`,
//! `State.deinit`, and `render`), its shaders in the Metal Shading
//! Language (see `gfx.MetalContext`).

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
const Node = widget.Node;
const Event = widget.Event;
const PointerCursor = widget.PointerCursor;
const ValueCallback = widget.ValueCallback;
const Border = decorated.Border;

pub fn MetalArea(comptime Scene: type) type {
    return struct {
        const Self = @This();
        const HasState = @hasDecl(Scene, "State");

        scene: Scene,
        samples: u8 = 4,
        clear_color: ?gfx.Color = null,
        radius: gfx.Radii = .all(12),
        border: ?Border = null,
        on_drag: ?ValueCallback(Point) = null,
        min_width: f32 = 280,
        min_height: f32 = 260,
        key: ?u64 = null,
        child: ?Widget = null,

        pub const State = struct {
            gpa: ?std.mem.Allocator = null,
            mtl_ctx: ?gfx.MetalContext = null,
            scene_state: if (HasState) ?Scene.State else void = if (HasState) null else {},
            init_failed: bool = false,
            dragging: bool = false,
            last_pos: Point = .{ 0, 0 },

            pub fn deinit(st: *State) void {
                if (st.mtl_ctx) |*ctx| {
                    ctx.waitIdle();
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
                    st.mtl_ctx = null;
                }
            }
        };

        const DrawPayload = struct {
            mtl_ctx: *gfx.MetalContext,
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
                    if (pr.button != widget.btn_left) return false;
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

            if (!st.init_failed and st.mtl_ctx == null) {
                st.gpa = n.ui.gpa;
                // On the UI's Metal renderer's device if it has one, so that
                // the scene is drawn straight into its frames; or else on a
                // device of its own, and copied in.
                const shared: ?gfx.MetalContext = if (sharedDevice(n)) |dev| gfx.MetalContext.initShared(n.ui.gpa, dev) catch null else null;
                if (if (shared) |ctx| ctx else gfx.MetalContext.init(n.ui.gpa)) |ctx| {
                    st.mtl_ctx = ctx;
                    if (HasState) {
                        const params = @typeInfo(@TypeOf(Scene.State.init)).@"fn".param_types;
                        const init_res = if (params.len == 2)
                            Scene.State.init(&st.mtl_ctx.?, n.ui.gpa)
                        else
                            Scene.State.init(&st.mtl_ctx.?);
                        if (init_res) |ss| {
                            st.scene_state = ss;
                        } else |_| {
                            st.mtl_ctx.?.deinit();
                            st.mtl_ctx = null;
                            st.init_failed = true;
                        }
                    }
                } else |_| {
                    st.init_failed = true;
                }
            }

            if (st.mtl_ctx == null) {
                const c = p.canvas();
                c.fillRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, self.radius, bg);
                if (self.border) |b| {
                    c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = n.size.w - 1, .h = n.size.h - 1 }, self.radius, b.width, b.color);
                }
                return;
            }

            const payload = n.ui.arena().create(DrawPayload) catch return;
            payload.* = .{
                .mtl_ctx = &st.mtl_ctx.?,
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

        /// The device of the UI's renderer, if it is the Metal one.
        fn sharedDevice(n: *Node) ?gfx.metal.SharedDevice {
            const vr = &(n.ui.shared.metal_renderer orelse return null);
            const r = n.ui.shared.renderer orelse return null;
            if (r.ptr != @as(*anyopaque, @ptrCast(vr))) return null;
            return vr.sharedDevice();
        }

        fn drawDirect(payload: *const DrawPayload, backend: gfx.RenderBackend, frame: *const anyopaque, area: gfx.GpuArea) anyerror!bool {
            if (backend != .metal) return false;
            const f: *const gfx.metal.DirectFrame = @ptrCast(@alignCast(frame));
            return payload.mtl_ctx.renderToFrame(f, area, payload.clear_color, payload.samples, payload, renderScene);
        }

        fn drawGpu(payload: *const DrawPayload, target: *gfx.software.Image, area: gfx.GpuArea) anyerror!void {
            try payload.mtl_ctx.renderToImage(target, area, payload.clear_color, payload.samples, payload, renderScene);
        }

        fn renderScene(payload: *const DrawPayload, ctx: *gfx.MetalContext) anyerror!void {
            if (HasState) {
                try payload.scene.render(payload.scene_state, ctx);
            } else {
                try payload.scene.render(ctx);
            }
        }
    };
}
