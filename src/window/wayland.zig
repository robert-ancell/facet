//! Wayland client window (`xdg_toplevel` + `wl_shm` shared-memory buffers)
//! with pointer, touch, keyboard (including key repeat), cursor shapes
//! (`wp_cursor_shape_v1`), clipboard and drag-and-drop (`wl_data_device`),
//! text input (`zwp_text_input_v3`), pointer lock (`zwp_pointer_constraints_v1`),
//! and presentation feedback (`wp_presentation`).

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");
const gfx = @import("gfx");
const window_mod = @import("window.zig");
const clipboard_mod = @import("clipboard.zig");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

pub const Clipboard = clipboard_mod.Clipboard;
pub const DroppedData = clipboard_mod.DroppedData;
pub const InputEvent = window_mod.InputEvent;
pub const TextInputState = window_mod.TextInputState;
pub const Cursor = window_mod.Cursor;
pub const Keyboard = window_mod.Keyboard;
pub const nowNs = clipboard_mod.nowNs;

const default_size = [2]u32{ 1280, 720 };

pub const shadow_margin: u32 = 28;
pub const corner_radius: f32 = 12.0;
pub const resize_outset: f32 = 10.0;
pub const resize_border = 6;
pub const resize_corner = 20;

pub const edge_top = 1;
pub const edge_bottom = 2;
pub const edge_left = 4;
pub const edge_right = 8;

const max_buffers = 2;

inline fn sdfRoundedBox(dx: f32, dy: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(dx) - hx;
    const qy = @abs(dy) - hy;
    const mx = @max(qx, 0.0);
    const my = @max(qy, 0.0);
    return @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0.0) - r;
}

inline fn shadowAlphaAt(px: f32, py: f32, cx0: f32, cy0: f32, hx: f32, hy: f32, r: f32, sf: f32, d_win: f32) f32 {
    const d_key = sdfRoundedBox(px - cx0, py - (cy0 + 4.0 * sf), hx, hy, r);
    const key_rad = 22.0 * sf;
    const u_key = std.math.clamp(1.0 - @max(d_key, 0.0) / key_rad, 0.0, 1.0);
    const t_key = u_key * u_key * u_key;

    const d_amb = sdfRoundedBox(px - cx0, py - (cy0 + 1.0 * sf), hx, hy, r);
    const amb_rad = 7.0 * sf;
    const u_amb = std.math.clamp(1.0 - @max(d_amb, 0.0) / amb_rad, 0.0, 1.0);
    const t_amb = u_amb * u_amb * (3.0 - 2.0 * u_amb);

    const outline_a = if (d_win >= -0.5 and d_win <= 1.2 * sf)
        0.18 * std.math.clamp(1.0 - @abs(d_win - 0.3 * sf) / (0.9 * sf), 0.0, 1.0)
    else
        0.0;

    return std.math.clamp(0.28 * t_key + 0.14 * t_amb + outline_a, 0.0, 1.0);
}

pub const GbmDevice = opaque {};
pub const GbmBo = opaque {};

pub const DmaBufDevice = struct {
    drm_lib: std.DynLib,
    gbm_lib: std.DynLib,
    drm_fd: linux.fd_t,
    gbm_dev: *GbmDevice,
    drm: DrmProcs,
    gbm: GbmProcs,
    supports_syncobj: bool = false,

    const drm_node_primary = 0;
    const drm_node_render = 2;

    const DrmDevice = extern struct {
        nodes: [*][*:0]u8,
        available_nodes: c_int,
        bustype: c_int,
        businfo: ?*anyopaque,
        deviceinfo: ?*anyopaque,
    };

    pub const DrmProcs = struct {
        GetDevices2: *const fn (u32, ?[*]*DrmDevice, c_int) callconv(.c) c_int,
        FreeDevices: *const fn ([*]*DrmDevice, c_int) callconv(.c) void,
        SyncobjCreate: ?*const fn (c_int, u32, *u32) callconv(.c) c_int = null,
        SyncobjDestroy: ?*const fn (c_int, u32) callconv(.c) c_int = null,
        SyncobjHandleToFD: ?*const fn (c_int, u32, *c_int) callconv(.c) c_int = null,
        SyncobjTimelineSignal: ?*const fn (c_int, *const u32, *const u64, u32) callconv(.c) c_int = null,
        SyncobjTimelineWait: ?*const fn (c_int, *u32, *u64, u32, i64, u32, ?*u32) callconv(.c) c_int = null,

        fn load(lib: *std.DynLib) !DrmProcs {
            return .{
                .GetDevices2 = lib.lookup(*const fn (u32, ?[*]*DrmDevice, c_int) callconv(.c) c_int, "drmGetDevices2") orelse return error.MissingDrmFunction,
                .FreeDevices = lib.lookup(*const fn ([*]*DrmDevice, c_int) callconv(.c) void, "drmFreeDevices") orelse return error.MissingDrmFunction,
                .SyncobjCreate = lib.lookup(*const fn (c_int, u32, *u32) callconv(.c) c_int, "drmSyncobjCreate"),
                .SyncobjDestroy = lib.lookup(*const fn (c_int, u32) callconv(.c) c_int, "drmSyncobjDestroy"),
                .SyncobjHandleToFD = lib.lookup(*const fn (c_int, u32, *c_int) callconv(.c) c_int, "drmSyncobjHandleToFD"),
                .SyncobjTimelineSignal = lib.lookup(*const fn (c_int, *const u32, *const u64, u32) callconv(.c) c_int, "drmSyncobjTimelineSignal"),
                .SyncobjTimelineWait = lib.lookup(*const fn (c_int, *u32, *u64, u32, i64, u32, ?*u32) callconv(.c) c_int, "drmSyncobjTimelineWait"),
            };
        }
    };

    pub const GbmProcs = struct {
        create_device: *const fn (c_int) callconv(.c) ?*GbmDevice,
        device_destroy: *const fn (*GbmDevice) callconv(.c) void,
        bo_create: *const fn (*GbmDevice, u32, u32, u32, u32) callconv(.c) ?*GbmBo,
        bo_destroy: *const fn (*GbmBo) callconv(.c) void,
        bo_map: *const fn (*GbmBo, u32, u32, u32, u32, u32, *u32, *?*anyopaque) callconv(.c) ?[*]u8,
        bo_unmap: *const fn (*GbmBo, ?*anyopaque) callconv(.c) void,
        bo_get_fd: *const fn (*GbmBo) callconv(.c) c_int,
        bo_get_stride: *const fn (*GbmBo) callconv(.c) u32,
        bo_get_offset: *const fn (*GbmBo, c_int) callconv(.c) u32,
        bo_get_modifier: *const fn (*GbmBo) callconv(.c) u64,

        fn load(lib: *std.DynLib) !GbmProcs {
            var procs: GbmProcs = undefined;
            inline for (@typeInfo(GbmProcs).@"struct".field_names) |field_name| {
                const sym_name: [:0]const u8 = "gbm_" ++ field_name;
                @field(procs, field_name) = lib.lookup(@FieldType(GbmProcs, field_name), sym_name) orelse return error.MissingGbmFunction;
            }
            return procs;
        }
    };

    pub const gbm_bo_use_rendering: u32 = 1 << 2;
    pub const gbm_bo_use_write: u32 = 1 << 3;
    pub const gbm_bo_use_linear: u32 = 1 << 4;

    pub const gbm_bo_transfer_read: u32 = 1 << 0;
    pub const gbm_bo_transfer_write: u32 = 1 << 1;
    pub const gbm_bo_transfer_read_write: u32 = gbm_bo_transfer_read | gbm_bo_transfer_write;

    pub const Allocation = struct {
        bo: *GbmBo,
        dmabuf_fd: linux.fd_t,
        stride: u32,
        offset: u32,
        modifier: u64,
    };

    pub fn open() ?DmaBufDevice {
        var drm_lib = std.DynLib.open("libdrm.so.2") catch std.DynLib.open("libdrm.so") catch return null;
        const drm = DrmProcs.load(&drm_lib) catch {
            drm_lib.close();
            return null;
        };

        var gbm_lib = std.DynLib.open("libgbm.so.1") catch std.DynLib.open("libgbm.so") catch {
            drm_lib.close();
            return null;
        };
        const gbm = GbmProcs.load(&gbm_lib) catch {
            gbm_lib.close();
            drm_lib.close();
            return null;
        };

        var devices: [16]*DrmDevice = undefined;
        const count = drm.GetDevices2(0, &devices, devices.len);
        if (count > 0) {
            const n: usize = @intCast(count);
            defer drm.FreeDevices(&devices, count);
            for ([_]u5{ drm_node_render, drm_node_primary }) |node_type| {
                for (devices[0..n]) |dev| {
                    if ((dev.available_nodes & (@as(c_int, 1) << node_type)) == 0) continue;
                    if (tryOpenNode(dev.nodes[node_type], drm_lib, gbm_lib, drm, gbm)) |d| return d;
                }
            }
        }

        gbm_lib.close();
        drm_lib.close();
        return null;
    }

    fn tryOpenNode(path: [*:0]const u8, drm_lib: std.DynLib, gbm_lib: std.DynLib, drm: DrmProcs, gbm: GbmProcs) ?DmaBufDevice {
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: linux.fd_t = @intCast(rc);
        const gbm_dev = gbm.create_device(fd) orelse {
            _ = linux.close(fd);
            return null;
        };
        var supports_syncobj = false;
        if (drm.SyncobjCreate != null and drm.SyncobjDestroy != null and drm.SyncobjHandleToFD != null and drm.SyncobjTimelineSignal != null and drm.SyncobjTimelineWait != null) {
            var handle: u32 = 0;
            if (drm.SyncobjCreate.?(fd, 0, &handle) == 0) {
                var pt: u64 = 1;
                if (drm.SyncobjTimelineSignal.?(fd, &handle, &pt, 1) == 0) {
                    var obj_fd: c_int = -1;
                    if (drm.SyncobjHandleToFD.?(fd, handle, &obj_fd) == 0 and obj_fd >= 0) {
                        _ = linux.close(obj_fd);
                        supports_syncobj = true;
                    }
                }
                _ = drm.SyncobjDestroy.?(fd, handle);
            }
        }
        const dev: DmaBufDevice = .{
            .drm_lib = drm_lib,
            .gbm_lib = gbm_lib,
            .drm_fd = fd,
            .gbm_dev = gbm_dev,
            .drm = drm,
            .gbm = gbm,
            .supports_syncobj = supports_syncobj,
        };
        if (dev.alloc(4, 4, p.fourcc.argb8888)) |probe| {
            _ = linux.close(probe.dmabuf_fd);
            dev.gbm.bo_destroy(probe.bo);
            return dev;
        } else |_| {
            dev.gbm.device_destroy(gbm_dev);
            _ = linux.close(fd);
            return null;
        }
    }

    pub fn close(dev: *DmaBufDevice) void {
        dev.gbm.device_destroy(dev.gbm_dev);
        if (dev.drm_fd >= 0) _ = linux.close(dev.drm_fd);
        dev.gbm_lib.close();
        dev.drm_lib.close();
    }

    pub fn alloc(dev: *const DmaBufDevice, width: u32, height: u32, format: u32) !Allocation {
        const flags = gbm_bo_use_rendering | gbm_bo_use_linear;
        const bo = dev.gbm.bo_create(dev.gbm_dev, width, height, format, flags) orelse
            dev.gbm.bo_create(dev.gbm_dev, width, height, format, gbm_bo_use_linear) orelse
            dev.gbm.bo_create(dev.gbm_dev, width, height, format, gbm_bo_use_write) orelse
            return error.OutOfMemory;
        errdefer dev.gbm.bo_destroy(bo);

        const fd = dev.gbm.bo_get_fd(bo);
        if (fd < 0) return error.OutOfMemory;
        return .{
            .bo = bo,
            .dmabuf_fd = fd,
            .stride = dev.gbm.bo_get_stride(bo),
            .offset = dev.gbm.bo_get_offset(bo, 0),
            .modifier = dev.gbm.bo_get_modifier(bo),
        };
    }
};

pub const Buffer = struct {
    pub const drm_syncobj_wait_flags_wait_all: u32 = 1 << 0;
    pub const drm_syncobj_wait_flags_wait_for_submit: u32 = 1 << 1;

    drawn: u64 = 0,
    bo: ?*GbmBo = null,
    gbm: ?DmaBufDevice.GbmProcs = null,
    drm_fd: linux.fd_t = -1,
    drm: ?DmaBufDevice.DrmProcs = null,
    syncobj_handle: u32 = 0,
    syncobj_timeline: client.Proxy = .{},
    syncobj_point: u64 = 0,
    release_point: u64 = 0,
    map_data: ?*anyopaque = null,
    pixels: []u8 = &.{},
    pool: client.Proxy = .{},
    proxy: client.Proxy = .{},
    width: u32,
    height: u32,
    stride_words: u32 = 0,
    content_w: u32 = 0,
    content_h: u32 = 0,
    margin: u32 = 0,
    scale: u32 = 1,
    busy: bool = false,
    shadow_drawn: bool = false,

    pub inline fn rowWords(b: *const Buffer) u32 {
        return if (b.stride_words > 0) b.stride_words else b.width;
    }

    /// True when the compositor has finished reading the buffer (either via
    /// `wp_linux_drm_syncobj_v1` release timeline point or `wl_buffer.release`).
    pub fn isReady(b: *Buffer) bool {
        if (b.release_point > 0) {
            if (b.drm) |drm| if (drm.SyncobjTimelineWait) |wait_fn| {
                var handle = b.syncobj_handle;
                var pt = b.release_point;
                if (wait_fn(b.drm_fd, &handle, &pt, 1, 0, drm_syncobj_wait_flags_wait_all, null) == 0) {
                    b.release_point = 0;
                    b.busy = false;
                    return true;
                }
            };
            return false;
        }
        return !b.busy;
    }

    /// Waits up to `timeout_ns` for the buffer's explicit release timeline point
    /// to signal, returning true once the buffer is ready for reuse.
    pub fn waitReady(b: *Buffer, timeout_ns: u64) bool {
        if (b.release_point > 0) {
            if (b.drm) |drm| if (drm.SyncobjTimelineWait) |wait_fn| {
                var handle = b.syncobj_handle;
                var pt = b.release_point;
                const deadline: i64 = @intCast(@min(nowNs() +| timeout_ns, @as(u64, std.math.maxInt(i64))));
                const flags = drm_syncobj_wait_flags_wait_all | drm_syncobj_wait_flags_wait_for_submit;
                if (wait_fn(b.drm_fd, &handle, &pt, 1, deadline, flags, null) == 0) {
                    b.release_point = 0;
                    b.busy = false;
                    return true;
                }
            };
            return false;
        }
        return !b.busy;
    }

    pub fn beginCpuAccess(b: *Buffer) !void {
        const bo = b.bo orelse return;
        if (b.map_data != null) return;
        const gbm = b.gbm orelse return error.OutOfMemory;
        var map_stride: u32 = 0;
        var map_data: ?*anyopaque = null;
        const ptr = gbm.bo_map(
            bo,
            0,
            0,
            b.width,
            b.height,
            DmaBufDevice.gbm_bo_transfer_read_write,
            &map_stride,
            &map_data,
        ) orelse return error.OutOfMemory;
        b.map_data = map_data;
        b.stride_words = map_stride / 4;
        b.pixels = ptr[0 .. @as(usize, map_stride) * @as(usize, b.height)];
    }

    pub fn endCpuAccess(b: *Buffer) void {
        const bo = b.bo orelse return;
        if (b.map_data == null) return;
        if (b.gbm) |gbm| {
            gbm.bo_unmap(bo, b.map_data);
        }
        b.map_data = null;
        b.pixels = &.{};
    }

    /// Returns the window content sub-image (inside the shadow margin) with
    /// `stride` set to the full buffer row stride in `u32` words.
    pub fn image(b: *Buffer) gfx.software.Image {
        const cw = if (b.content_w > 0) b.content_w else b.width;
        const ch = if (b.content_h > 0) b.content_h else b.height;
        const sw = b.rowWords();
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        const total = @as(usize, sw) * @as(usize, b.height);
        const start = @as(usize, b.margin) * @as(usize, sw) + @as(usize, b.margin);
        return .{
            .pixels = words[start..total],
            .stride = sw,
            .width = cw,
            .height = ch,
        };
    }

    /// Renders the drop shadow into the outer margin around the window content.
    pub fn renderShadowMargin(b: *Buffer) void {
        if (b.shadow_drawn or b.margin == 0 or b.content_w == 0 or b.content_h == 0) return;
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        const m = b.margin;
        const cw = b.content_w;
        const ch = b.content_h;
        const bw = b.width;
        const bh = b.height;
        const sw = b.rowWords();
        const sf: f32 = @floatFromInt(@max(b.scale, 1));
        const r = corner_radius * sf;
        const f_m: f32 = @floatFromInt(m);
        const f_cw: f32 = @floatFromInt(cw);
        const f_ch: f32 = @floatFromInt(ch);
        const cx0 = f_m + f_cw * 0.5;
        const cy0 = f_m + f_ch * 0.5;
        const hx = @max(f_cw * 0.5 - r, 0.0);
        const hy = @max(f_ch * 0.5 - r, 0.0);

        for (0..bh) |by| {
            const py = @as(f32, @floatFromInt(by)) + 0.5;
            const row = words[by * sw ..][0..bw];
            const in_y = by >= m and by < m + ch;
            if (!in_y) {
                for (0..bw) |bx| {
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const a_u32: u32 = @intFromFloat(@round(sa * 255.0));
                    row[bx] = a_u32 << 24;
                }
            } else {
                for (0..m) |bx| {
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const a_u32: u32 = @intFromFloat(@round(sa * 255.0));
                    row[bx] = a_u32 << 24;
                }
                for (m + cw..bw) |bx| {
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const a_u32: u32 = @intFromFloat(@round(sa * 255.0));
                    row[bx] = a_u32 << 24;
                }
            }
        }
        b.shadow_drawn = true;
    }

    /// Rounds the 4 corners of the window content over the drop shadow for any
    /// corner pixels covered by `repainted` (or all 4 corners if `repainted == null`).
    pub fn applyRoundedCorners(b: *Buffer, repainted: ?[]const gfx.Viewport) void {
        if (b.margin == 0 or b.content_w == 0 or b.content_h == 0) return;
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        const m = b.margin;
        const cw = b.content_w;
        const ch = b.content_h;
        const sw = b.rowWords();
        const sf: f32 = @floatFromInt(@max(b.scale, 1));
        const r = corner_radius * sf;
        const corner_px: u32 = @min(@as(u32, @intFromFloat(@ceil(r))) + 1, @min(cw / 2, ch / 2));
        if (corner_px == 0) return;

        const f_m: f32 = @floatFromInt(m);
        const f_cw: f32 = @floatFromInt(cw);
        const f_ch: f32 = @floatFromInt(ch);
        const cx0 = f_m + f_cw * 0.5;
        const cy0 = f_m + f_ch * 0.5;
        const hx = @max(f_cw * 0.5 - r, 0.0);
        const hy = @max(f_ch * 0.5 - r, 0.0);

        const corners = [4][2]u32{
            .{ 0, 0 },
            .{ cw - corner_px, 0 },
            .{ 0, ch - corner_px },
            .{ cw - corner_px, ch - corner_px },
        };

        for (corners) |c0| {
            var cy: u32 = c0[1];
            while (cy < c0[1] + corner_px) : (cy += 1) {
                var cx: u32 = c0[0];
                while (cx < c0[0] + corner_px) : (cx += 1) {
                    if (repainted) |vps| {
                        var in_vp = false;
                        for (vps) |vp| {
                            if (cx >= @as(u32, @intCast(@max(vp.x, 0))) and
                                cy >= @as(u32, @intCast(@max(vp.y, 0))) and
                                @as(i32, @intCast(cx)) < vp.x + @as(i32, @intCast(vp.width)) and
                                @as(i32, @intCast(cy)) < vp.y + @as(i32, @intCast(vp.height)))
                            {
                                in_vp = true;
                                break;
                            }
                        }
                        if (!in_vp) continue;
                    }

                    const bx = m + cx;
                    const by = m + cy;
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const py = @as(f32, @floatFromInt(by)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    if (d_win <= -0.5) continue;

                    const cov = std.math.clamp(0.5 - d_win, 0.0, 1.0);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const idx = @as(usize, by) * sw + bx;
                    const src = words[idx];
                    const sr: f32 = @floatFromInt((src >> 16) & 0xff);
                    const sg: f32 = @floatFromInt((src >> 8) & 0xff);
                    const sb: f32 = @floatFromInt(src & 0xff);
                    const src_a: f32 = (@as(f32, @floatFromInt((src >> 24) & 0xff)) / 255.0) * cov;
                    const out_a: u32 = @intFromFloat(@round(std.math.clamp(src_a + sa * (1.0 - src_a), 0.0, 1.0) * 255.0));
                    const out_r: u32 = @intFromFloat(@round(sr * cov));
                    const out_g: u32 = @intFromFloat(@round(sg * cov));
                    const out_b: u32 = @intFromFloat(@round(sb * cov));
                    words[idx] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
                }
            }
        }
    }
};

pub const WaylandWindow = struct {
    pub const platform: window_mod.Platform = .wayland;

    pub fn usingDmabuf(w: *const WaylandWindow) bool {
        return w.dmabuf != null and w.dmabuf_dev != null and (w.dmabuf_argb8888 or w.dmabuf_xrgb8888);
    }

    pub fn usingDrmSyncobj(w: *const WaylandWindow) bool {
        if (w.syncobj_surface != null) return true;
        if (!w.usingDmabuf()) return false;
        if (w.drm_syncobj_manager == null) return false;
        return w.dmabuf_dev.?.supports_syncobj;
    }

    /// Stops using explicit synchronization (`wp_linux_drm_syncobj_v1`) for
    /// the window, for good. It is all or nothing: while the surface has a
    /// syncobj surface, every buffer committed must have timeline points,
    /// and must be a dmabuf. Points already committed are still signalled.
    fn stopSyncobj(w: *WaylandWindow) void {
        if (w.syncobj_surface) |ss| {
            if (ss.request(p.wp_linux_drm_syncobj_surface_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(ss.id);
            w.syncobj_surface = null;
        }
        if (w.drm_syncobj_manager) |mgr| {
            if (mgr.request(p.wp_linux_drm_syncobj_manager_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(mgr.id);
            w.drm_syncobj_manager = null;
        }
        w.updateExtensions();
    }

    pub fn bufferTransport(w: *const WaylandWindow) window_mod.BufferTransport {
        return if (w.usingDmabuf()) .linux_dmabuf else .wl_shm;
    }

    pub fn bufferSync(w: *const WaylandWindow) window_mod.BufferSync {
        if (w.usingDrmSyncobj()) return .linux_drm_syncobj_v1;
        return if (w.usingDmabuf()) .implicit else .none;
    }

    pub fn frameSync(w: *const WaylandWindow) window_mod.FrameSync {
        return .{
            .vsync = w.vsync,
            .frame_callback = w.vsync,
            .presentation_time = w.presentation != null,
            .fifo_v1 = w.fifo != null,
            .commit_timing_v1 = w.commit_timer != null,
        };
    }

    pub fn refreshHz(w: *const WaylandWindow) f32 {
        if (w.refresh_ns == 0) return 0.0;
        return @as(f32, @floatFromInt(std.time.ns_per_s)) / @as(f32, @floatFromInt(w.refresh_ns));
    }

    pub fn extensions(w: *const WaylandWindow) []const []const u8 {
        return w.extensions_buf[0..w.extensions_len];
    }

    pub fn decorations(w: *const WaylandWindow) window_mod.Decorations {
        return if (w.server_decorations) .server else .client;
    }

    pub fn getTitle(w: *const WaylandWindow) []const u8 {
        return w.title_buf[0..w.title_len];
    }

    gpa: std.mem.Allocator,
    conn: *client.Display,
    globals: client.Globals = .{},
    compositor: client.Proxy = .{},
    wm_base: client.Proxy = .{},
    shm: client.Proxy = .{},
    dmabuf: ?client.Proxy = null,
    dmabuf_dev: ?DmaBufDevice = null,
    dmabuf_argb8888: bool = false,
    dmabuf_xrgb8888: bool = false,
    drm_syncobj_manager: ?client.Proxy = null,
    syncobj_surface: ?client.Proxy = null,
    surface: client.Proxy = .{},
    xdg_surface: client.Proxy = .{},
    toplevel: client.Proxy = .{},
    decoration_manager: ?client.Proxy = null,
    toplevel_decoration: ?client.Proxy = null,

    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    width: u32 = default_size[0],
    height: u32 = default_size[1],
    min_size: [2]u32 = .{ 0, 0 },
    scale: u32 = 1,
    server_decorations: bool = false,
    decoration_changed: bool = false,
    last_geometry: ?[3]u32 = null,
    next_size: [2]i32 = .{ 0, 0 },
    pending_serial: ?u32 = null,
    closed: bool = false,
    suspended: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    tiled: bool = false,
    vsync: bool = true,
    press_serial: u32 = 0,
    buttons_down: u32 = 0,
    enter_serial: u32 = 0,

    cursor_shape_manager: ?client.Proxy = null,
    cursor_device: ?client.Proxy = null,
    cursor_shape: ?u32 = null,
    app_cursor: Cursor = .default,

    buffers: [max_buffers]?Buffer = @splat(null),
    back: ?usize = null,
    frame_corners_applied: bool = false,
    frame_pending: bool = false,
    frames: u64 = 0,

    presentation: ?client.Proxy = null,
    presentation_clock_id: u32 = 1,
    presented_ns: u64 = 0,
    refresh_ns: u64 = 0,
    presentation_seq: u64 = 0,
    presentation_flags: u32 = 0,
    presented_frames: u64 = 0,
    discarded_frames: u64 = 0,

    fifo_manager: ?client.Proxy = null,
    fifo: ?client.Proxy = null,
    fifo_barrier_pending: bool = false,
    /// When the next frame shown is drawn for (`setPresentationTime`).
    target_ns: ?u64 = null,
    commit_timing_manager: ?client.Proxy = null,
    commit_timer: ?client.Proxy = null,
    extensions_buf: [16][]const u8 = undefined,
    extensions_len: usize = 0,

    seat: ?client.Proxy = null,
    touch: ?client.Proxy = null,
    text_input_manager: ?client.Proxy = null,
    text_input: ?client.Proxy = null,
    text_input_entered: bool = false,
    text_input_enabled: bool = false,
    text_input_has_preedit: bool = false,
    text_input_serial: u32 = 0,
    text_input_state: TextInputState = .{},
    text_input_surrounding_buf: [256]u8 = undefined,
    text_input_pending_preedit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,
    } = null,
    text_input_pending_commit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
    } = null,
    text_input_pending_delete: ?struct {
        before_length: u32,
        after_length: u32,
    } = null,

    pointer_constraints: ?client.Proxy = null,
    relative_pointer_manager: ?client.Proxy = null,
    relative_pointer: ?client.Proxy = null,
    locked_pointer: ?client.Proxy = null,
    pointer_locked: bool = false,

    clipboard: Clipboard,
    layout: Keyboard = .us,
    wake_fd: ?linux.fd_t = null,
    wake_fds: [4]?linux.fd_t = @splat(null),
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,

    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    repeat: ?struct { code: u32, next_ns: u64 } = null,
    keys_down: std.bit_set.Static(256) = .empty,
    pointer_pos: [2]f32 = .{ 0, 0 },
    input: [64]InputEvent = undefined,
    input_len: usize = 0,

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = default_size,
        min_size: ?[2]u32 = null,
        maximized: bool = false,
    };

    /// Connects to the compositor named in `environ` (`WAYLAND_DISPLAY`
    /// under `XDG_RUNTIME_DIR`) and opens a window.
    pub fn open(gpa: std.mem.Allocator, environ: std.process.Environ, options: Options) !*WaylandWindow {
        var path_buf: [256]u8 = undefined;
        const path = try client.environSocketPath(&path_buf, environ);
        return openPath(gpa, path, options);
    }

    /// Connects to the compositor listening on `path` and opens a window.
    pub fn openPath(gpa: std.mem.Allocator, path: []const u8, options: Options) !*WaylandWindow {
        const conn = try client.Display.connect(gpa, path);
        errdefer conn.disconnect();
        return openOn(gpa, conn, options);
    }

    /// Opens a window on an existing connection, which the window then owns.
    /// Waits for the first configure.
    pub fn openOn(gpa: std.mem.Allocator, conn: *client.Display, options: Options) !*WaylandWindow {
        const w = try gpa.create(WaylandWindow);
        errdefer gpa.destroy(w);
        const min_size = options.min_size orelse [2]u32{ 0, 0 };
        w.* = .{
            .gpa = gpa,
            .conn = conn,
            .clipboard = .{ .gpa = gpa },
            .width = if (options.maximized) options.size[0] else @max(options.size[0], min_size[0]),
            .height = if (options.maximized) options.size[1] else @max(options.size[1], min_size[1]),
            .min_size = min_size,
            .maximized = options.maximized,
        };
        const tlen = @min(options.title.len, w.title_buf.len);
        @memcpy(w.title_buf[0..tlen], options.title[0..tlen]);
        w.title_len = tlen;
        w.clipboard.drag_callbacks = .{
            .ctx = w,
            .enter = onDragEnter,
            .motion = onDragMotion,
            .leave = onDragLeave,
            .drop = onDragDrop,
        };

        const registry = try w.globals.fetch(conn);
        w.compositor = (try w.globals.bind(registry, p.wl_compositor.name, 6, null)) orelse return error.NoCompositor;
        w.wm_base = (try w.globals.bind(registry, p.xdg_wm_base.name, 6, .{ .ptr = w, .handler = wmBaseEvent })) orelse return error.NoXdgShell;
        if (w.globals.find(p.zwp_linux_dmabuf_v1.name)) |gl| {
            if (gl.version >= 2) {
                if (DmaBufDevice.open()) |dev_val| {
                    var dev = dev_val;
                    errdefer dev.close();
                    if (try w.globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = w, .handler = dmabufEvent })) |dmabuf_proxy| {
                        w.dmabuf = dmabuf_proxy;
                        w.dmabuf_dev = dev;
                    } else {
                        dev.close();
                    }
                }
            }
        }
        errdefer if (w.dmabuf_dev) |*dev| dev.close();
        if (try w.globals.bind(registry, p.wl_shm.name, 1, null)) |shm_proxy| {
            w.shm = shm_proxy;
        } else if (w.dmabuf == null or w.dmabuf_dev == null) {
            return error.NoShm;
        }

        w.decoration_manager = try w.globals.bind(registry, p.zxdg_decoration_manager_v1.name, 1, null);
        w.cursor_shape_manager = try w.globals.bind(registry, p.wp_cursor_shape_manager_v1.name, 1, null);
        w.presentation = try w.globals.bind(registry, p.wp_presentation.name, p.wp_presentation.version, .{ .ptr = w, .handler = presentationEvent });
        w.fifo_manager = try w.globals.bind(registry, p.wp_fifo_manager_v1.name, 1, null);
        w.commit_timing_manager = try w.globals.bind(registry, p.wp_commit_timing_manager_v1.name, 1, null);
        if (w.dmabuf != null and w.dmabuf_dev != null and w.dmabuf_dev.?.supports_syncobj) {
            w.drm_syncobj_manager = try w.globals.bind(registry, p.wp_linux_drm_syncobj_manager_v1.name, 1, null);
        }
        w.pointer_constraints = try w.globals.bind(registry, p.zwp_pointer_constraints_v1.name, 1, null);
        w.relative_pointer_manager = try w.globals.bind(registry, p.zwp_relative_pointer_manager_v1.name, 1, null);
        w.seat = try w.globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = w, .handler = seatEvent });

        try w.clipboard.attach(conn, try w.globals.bind(registry, p.wl_data_device_manager.name, 3, null), w.seat);

        w.text_input_manager = try w.globals.bind(registry, p.zwp_text_input_manager_v3.name, 1, null);
        if (w.text_input_manager) |mgr| if (w.seat) |seat| {
            const ti = try conn.newObject(.{ .ptr = w, .handler = textInputEvent });
            var m = try mgr.request(p.zwp_text_input_manager_v3.request.get_text_input);
            m.uint(ti.id).uint(seat.id).end();
            w.text_input = ti;
        };

        w.surface = try conn.newObject(.{ .ptr = w, .handler = surfaceEvent });
        var m = try w.compositor.request(p.wl_compositor.request.create_surface);
        m.uint(w.surface.id).end();
        if (w.fifo_manager) |mgr| {
            const fifo = try conn.newObject(null);
            m = try mgr.request(p.wp_fifo_manager_v1.request.get_fifo);
            m.uint(fifo.id).uint(w.surface.id).end();
            w.fifo = fifo;
        }
        if (w.commit_timing_manager) |mgr| {
            const timer = try conn.newObject(null);
            m = try mgr.request(p.wp_commit_timing_manager_v1.request.get_timer);
            m.uint(timer.id).uint(w.surface.id).end();
            w.commit_timer = timer;
        }
        w.xdg_surface = try conn.newObject(.{ .ptr = w, .handler = xdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(w.xdg_surface.id).uint(w.surface.id).end();
        w.toplevel = try conn.newObject(.{ .ptr = w, .handler = toplevelEvent });
        m = try w.xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(w.toplevel.id).end();
        if (w.decoration_manager) |mgr| {
            const dec = try conn.newObject(.{ .ptr = w, .handler = decorationEvent });
            m = try mgr.request(p.zxdg_decoration_manager_v1.request.get_toplevel_decoration);
            m.uint(dec.id).uint(w.toplevel.id).end();
            w.toplevel_decoration = dec;
        }
        m = try w.toplevel.request(p.xdg_toplevel.request.set_title);
        m.string(options.title).end();
        if (options.app_id) |app_id| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
            m.string(app_id).end();
        }
        if (options.min_size) |ms| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_min_size);
            m.int(@intCast(ms[0])).int(@intCast(ms[1])).end();
        }
        if (options.maximized) {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_maximized);
            m.end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        _ = try w.applyConfigure();
        w.updateExtensions();
        return w;
    }

    pub fn updateExtensions(w: *WaylandWindow) void {
        var n: usize = 0;
        if (w.wm_base.id != 0) {
            w.extensions_buf[n] = p.xdg_wm_base.name;
            n += 1;
        }
        if (w.usingDmabuf()) {
            w.extensions_buf[n] = p.zwp_linux_dmabuf_v1.name;
            n += 1;
        }
        if (w.usingDrmSyncobj()) {
            w.extensions_buf[n] = p.wp_linux_drm_syncobj_manager_v1.name;
            n += 1;
        }
        if (w.presentation != null) {
            w.extensions_buf[n] = p.wp_presentation.name;
            n += 1;
        }
        if (w.fifo != null) {
            w.extensions_buf[n] = p.wp_fifo_manager_v1.name;
            n += 1;
        }
        if (w.commit_timer != null) {
            w.extensions_buf[n] = p.wp_commit_timing_manager_v1.name;
            n += 1;
        }
        if (w.decoration_manager != null) {
            w.extensions_buf[n] = p.zxdg_decoration_manager_v1.name;
            n += 1;
        }
        if (w.cursor_shape_manager != null) {
            w.extensions_buf[n] = p.wp_cursor_shape_manager_v1.name;
            n += 1;
        }
        if (w.text_input_manager != null) {
            w.extensions_buf[n] = p.zwp_text_input_manager_v3.name;
            n += 1;
        }
        if (w.pointer_constraints != null) {
            w.extensions_buf[n] = p.zwp_pointer_constraints_v1.name;
            n += 1;
        }
        if (w.relative_pointer_manager != null) {
            w.extensions_buf[n] = p.zwp_relative_pointer_manager_v1.name;
            n += 1;
        }
        w.extensions_len = n;
    }

    pub fn close(w: *WaylandWindow) void {
        w.clipboard.deinit();
        for (&w.buffers) |*slot| if (slot.*) |*b| w.freeBuffer(b, slot);
        if (w.syncobj_surface) |ss| {
            if (ss.request(p.wp_linux_drm_syncobj_surface_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(ss.id);
        }
        if (w.fifo) |fifo| {
            if (fifo.request(p.wp_fifo_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(fifo.id);
        }
        if (w.commit_timer) |timer| {
            if (timer.request(p.wp_commit_timer_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(timer.id);
        }
        if (w.dmabuf_dev) |*dev| dev.close();
        w.conn.flush() catch {};
        w.conn.disconnect();
        w.gpa.destroy(w);
    }

    pub fn interface(w: *WaylandWindow) window_mod.Window {
        return window_mod.Window.of(w);
    }

    pub fn setAppId(w: *WaylandWindow, app_id: []const u8) !void {
        var m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
        m.string(app_id).end();
    }

    pub fn poll(w: *WaylandWindow) !void {
        _ = try w.conn.dispatchPending();
        w.clipboard.service();
        w.serviceRepeat(nowNs());
    }

    pub fn setFullscreen(w: *WaylandWindow, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_fullscreen else p.xdg_toplevel.request.unset_fullscreen) catch return;
        if (on) _ = m.uint(0);
        m.end();
        w.conn.flush() catch {};
    }

    pub fn lockPointer(w: *WaylandWindow) bool {
        if (w.locked_pointer != null) return true;
        const constraints = w.pointer_constraints orelse return false;
        const pointer = w.pointer orelse return false;
        if (w.relative_pointer == null) return false;
        const lock = w.conn.newObject(.{ .ptr = w, .handler = lockEvent }) catch return false;
        var m = constraints.request(p.zwp_pointer_constraints_v1.request.lock_pointer) catch return false;
        m.uint(lock.id).uint(w.surface.id).uint(pointer.id).uint(0).uint(p.zwp_pointer_constraints_v1.lifetime.persistent).end();
        w.conn.flush() catch {};
        w.locked_pointer = lock;
        return true;
    }

    pub fn unlockPointer(w: *WaylandWindow) void {
        const lock = w.locked_pointer orelse return;
        if (lock.request(p.zwp_locked_pointer_v1.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(lock.id);
        w.locked_pointer = null;
        if (w.pointer_locked) {
            w.pointer_locked = false;
            w.pushInput(.{ .pointer_locked = false });
        }
        w.conn.flush() catch {};
    }

    fn lockEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const locked = opcode == p.zwp_locked_pointer_v1.event.locked;
        if (locked == w.pointer_locked) return;
        w.pointer_locked = locked;
        w.pushInput(.{ .pointer_locked = locked });
    }

    fn relativeEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_relative_pointer_v1.event.relative_motion) return;
        _ = r.uint() catch return;
        _ = r.uint() catch return;
        const dx: f32 = @floatCast(r.fixed() catch return);
        const dy: f32 = @floatCast(r.fixed() catch return);
        w.pushInput(.{ .relative_motion = .{ dx, dy } });
    }

    pub fn setMaximized(w: *WaylandWindow, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_maximized else p.xdg_toplevel.request.unset_maximized) catch return;
        m.end();
        w.conn.flush() catch {};
    }

    pub fn setMinSize(w: *WaylandWindow, width: u32, height: u32) void {
        if (w.isFloating()) {
            if (w.width < width) w.width = width;
            if (w.height < height) w.height = height;
        }
        if (w.min_size[0] == width and w.min_size[1] == height) return;
        w.min_size = .{ width, height };
        var m = w.toplevel.request(p.xdg_toplevel.request.set_min_size) catch return;
        m.int(@intCast(width)).int(@intCast(height)).end();
        w.conn.flush() catch {};
    }

    /// True when the window is neither maximized, fullscreen, nor tiled.
    pub fn isFloating(w: *const WaylandWindow) bool {
        return !w.maximized and !w.fullscreen and !w.tiled;
    }

    /// True when the window is floating and draws client-side drop shadows,
    /// rounded corners, and an outer resize border. False when using
    /// server-side decorations (`zxdg_toplevel_decoration_v1`), or when
    /// maximized, fullscreen, or tiled.
    pub fn hasClientDecorations(w: *const WaylandWindow) bool {
        return !w.server_decorations and w.isFloating();
    }

    pub fn frameMargin(w: *const WaylandWindow) u32 {
        return if (w.hasClientDecorations()) shadow_margin else 0;
    }

    pub fn edgesAt(w: *const WaylandWindow, pos: [2]f32) u32 {
        if (!w.hasClientDecorations()) return 0;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const x = pos[0];
        const y = pos[1];
        if (x < -resize_outset or y < -resize_outset or x >= width + resize_outset or y >= height + resize_outset) return 0;
        if (w.isInsideContent(pos)) return 0;

        var edges: u32 = 0;
        if (x < 0 or (x < corner_radius and (y < corner_radius or y >= height - corner_radius))) {
            edges |= edge_left;
        } else if (x >= width or (x >= width - corner_radius and (y < corner_radius or y >= height - corner_radius))) {
            edges |= edge_right;
        }
        if (y < 0 or (y < corner_radius and (x < corner_radius or x >= width - corner_radius))) {
            edges |= edge_top;
        } else if (y >= height or (y >= height - corner_radius and (x < corner_radius or x >= width - corner_radius))) {
            edges |= edge_bottom;
        }
        if (edges & (edge_left | edge_right) != 0 and edges & (edge_top | edge_bottom) == 0) {
            if (y < resize_corner) edges |= edge_top else if (y >= height - resize_corner) edges |= edge_bottom;
        }
        if (edges & (edge_top | edge_bottom) != 0 and edges & (edge_left | edge_right) == 0) {
            if (x < resize_corner) edges |= edge_left else if (x >= width - resize_corner) edges |= edge_right;
        }
        return edges;
    }

    pub fn setCursor(w: *WaylandWindow, cursor: Cursor) void {
        if (w.app_cursor == cursor) return;
        w.app_cursor = cursor;
        w.updateCursor();
    }

    /// `cursor`'s `wp_cursor_shape_device_v1.shape` code.
    fn cursorShape(cursor: Cursor) u32 {
        const sh = p.wp_cursor_shape_device_v1.shape;
        return switch (cursor) {
            inline else => |c| @field(sh, @tagName(c)),
        };
    }

    fn updateCursor(w: *WaylandWindow) void {
        const edges = if (w.buttons_down == 0) w.edgesAt(w.pointer_pos) else 0;
        const sh = p.wp_cursor_shape_device_v1.shape;
        const vertical = edges & (edge_top | edge_bottom);
        const horizontal = edges & (edge_left | edge_right);
        const shape: u32 = if (vertical != 0 and horizontal != 0)
            (if ((vertical == edge_top) == (horizontal == edge_left)) sh.nwse_resize else sh.nesw_resize)
        else if (horizontal != 0) sh.ew_resize else if (vertical != 0) sh.ns_resize else cursorShape(w.app_cursor);
        if (w.cursor_shape == shape) return;
        const device = w.cursor_device orelse return;
        var m = device.request(p.wp_cursor_shape_device_v1.request.set_shape) catch return;
        m.uint(w.enter_serial).uint(shape).end();
        w.cursor_shape = shape;
    }

    pub fn startDrag(w: *WaylandWindow, mime_type: []const u8, bytes: []const u8, actions: u32) bool {
        return w.clipboard.startDrag(w.surface, null, mime_type, bytes, actions);
    }

    pub fn takeDrop(w: *WaylandWindow) ?DroppedData {
        return w.clipboard.takeDrop();
    }

    /// The next frame shown is drawn for `target_ns`: with
    /// `wp_commit_timing_v1`, it is not shown before then.
    pub fn setPresentationTime(w: *WaylandWindow, target_ns: u64) void {
        w.target_ns = target_ns;
    }

    pub fn nextPresentationNs(w: *const WaylandWindow, now_ns: u64) u64 {
        if (w.presented_ns == 0 or w.refresh_ns == 0) return now_ns;
        if (now_ns < w.presented_ns) return w.presented_ns + w.refresh_ns;
        const elapsed = now_ns - w.presented_ns;
        const periods = elapsed / w.refresh_ns + 1;
        return w.presented_ns + periods * w.refresh_ns;
    }

    pub fn setTextInput(w: *WaylandWindow, state: ?TextInputState) void {
        const ti = w.text_input orelse return;
        if (!w.text_input_entered) {
            if (state) |s| {
                w.saveTextInputState(s);
                w.text_input_enabled = true;
            } else {
                w.text_input_enabled = false;
            }
            return;
        }
        if (state) |s| {
            if (w.text_input_enabled and w.text_input_state.eql(s)) return;
            const enabling = !w.text_input_enabled;
            w.saveTextInputState(s);
            w.text_input_enabled = true;
            w.sendTextInputState(ti, enabling);
        } else {
            if (!w.text_input_enabled) return;
            w.text_input_enabled = false;
            var m = ti.request(p.zwp_text_input_v3.request.disable) catch return;
            m.end();
            m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
            m.end();
            w.text_input_serial +%= 1;
            w.conn.flush() catch {};
        }
    }

    fn saveTextInputState(w: *WaylandWindow, s: TextInputState) void {
        const n = @min(s.surrounding_text.len, w.text_input_surrounding_buf.len);
        @memcpy(w.text_input_surrounding_buf[0..n], s.surrounding_text[0..n]);
        w.text_input_state = s;
        w.text_input_state.surrounding_text = w.text_input_surrounding_buf[0..n];
        w.text_input_state.cursor = @min(s.cursor, @as(u32, @intCast(n)));
        w.text_input_state.anchor = @min(s.anchor, @as(u32, @intCast(n)));
    }

    fn sendTextInputState(w: *WaylandWindow, ti: client.Proxy, send_enable: bool) void {
        const s = w.text_input_state;
        const ti_proto = p.zwp_text_input_v3;
        const hint: u32 = if (s.password)
            ti_proto.content_hint.hidden_text | ti_proto.content_hint.sensitive_data
        else if (s.multiline)
            ti_proto.content_hint.multiline
        else
            ti_proto.content_hint.none;
        const purpose: u32 = if (s.password) ti_proto.content_purpose.password else ti_proto.content_purpose.normal;
        const cause: u32 = switch (s.change_cause) {
            .input_method => ti_proto.change_cause.input_method,
            .other => ti_proto.change_cause.other,
        };
        if (send_enable) {
            var m = ti.request(p.zwp_text_input_v3.request.enable) catch return;
            m.end();
        }
        var m = ti.request(p.zwp_text_input_v3.request.set_surrounding_text) catch return;
        m.string(s.surrounding_text).uint(s.cursor).uint(s.anchor).end();
        m = ti.request(p.zwp_text_input_v3.request.set_text_change_cause) catch return;
        m.uint(cause).end();
        m = ti.request(p.zwp_text_input_v3.request.set_content_type) catch return;
        m.uint(hint).uint(purpose).end();
        m = ti.request(p.zwp_text_input_v3.request.set_cursor_rectangle) catch return;
        const m_off: i32 = @intCast(w.frameMargin());
        m.int(s.cursor_rect[0] + m_off).int(s.cursor_rect[1] + m_off).int(s.cursor_rect[2]).int(s.cursor_rect[3]).end();
        m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
        m.end();
        w.text_input_serial +%= 1;
        w.conn.flush() catch {};
    }

    pub fn startMove(w: *WaylandWindow) void {
        if (w.press_serial == 0) return;
        const seat = w.seat orelse return;
        var m = w.toplevel.request(p.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(w.press_serial).end();
        w.conn.flush() catch {};
    }

    pub fn wait(w: *WaylandWindow, timeout_ns: u64) !void {
        const now = nowNs();
        const caller_ms: u64 = std.math.divCeil(u64, timeout_ns, std.time.ns_per_ms) catch 0;
        const timeout_ms = @min(caller_ms, w.repeatTimeoutMs(now) orelse caller_ms);
        const paste_fd = w.clipboard.pasteFd();
        const has_wake_fds = for (w.wake_fds) |fd| {
            if (fd != null) break true;
        } else false;
        if (paste_fd == null and w.wake_fd == null and !has_wake_fds) {
            try w.conn.dispatchTimeout(@intCast(@min(timeout_ms, std.math.maxInt(i32))));
            w.serviceRepeat(nowNs());
            return;
        }
        try w.conn.flush();
        if (try w.conn.dispatchPending() == 0) {
            const ms = @min(timeout_ms, w.clipboard.pasteTimeoutMs() orelse timeout_ms, std.math.maxInt(i32));
            var fds: [3 + 4]linux.pollfd = undefined;
            var n: usize = 0;
            for ([_]?linux.fd_t{ w.conn.conn.fd, paste_fd, w.wake_fd }) |fd| if (fd) |f| {
                fds[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            for (w.wake_fds) |fd| if (fd) |f| {
                fds[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            _ = linux.poll(&fds, n, @intCast(ms));
            _ = try w.conn.dispatchPending();
        }
        w.clipboard.service();
        w.serviceRepeat(nowNs());
    }

    fn repeatTimeoutMs(w: *const WaylandWindow, now_ns: u64) ?u64 {
        const rep = w.repeat orelse return null;
        if (w.repeat_rate == 0) return null;
        if (now_ns >= rep.next_ns) return 0;
        return std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
    }

    pub fn serviceRepeat(w: *WaylandWindow, now_ns: u64) void {
        const rep = &(w.repeat orelse return);
        if (w.repeat_rate == 0) {
            w.repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, w.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        w.pushInput(.{ .key = .{ .code = rep.code, .pressed = true } });
    }

    pub fn applyConfigure(w: *WaylandWindow) !?[2]u32 {
        const serial = w.pending_serial orelse return null;
        w.pending_serial = null;
        const dec_changed = w.decoration_changed;
        w.decoration_changed = false;
        var size = [2]u32{
            if (w.next_size[0] > 0) @intCast(w.next_size[0]) else w.width,
            if (w.next_size[1] > 0) @intCast(w.next_size[1]) else w.height,
        };
        if (w.isFloating()) {
            size[0] = @max(size[0], w.min_size[0]);
            size[1] = @max(size[1], w.min_size[1]);
        }
        var m = try w.xdg_surface.request(p.xdg_surface.request.ack_configure);
        m.uint(serial).end();
        if (size[0] == w.width and size[1] == w.height and !dec_changed) return null;
        w.width = size[0];
        w.height = size[1];
        return size;
    }

    /// Acquires a free `linux_dmabuf` (or `wl_shm` fallback) buffer of the
    /// window's current size and returns its inner content CPU pixel slice as
    /// a `gfx.software.Image`.
    pub fn beginFrame(w: *WaylandWindow) !gfx.software.Image {
        const i = w.back orelse try w.pickBack();
        w.back = i;
        w.frame_corners_applied = false;
        try w.buffers[i].?.beginCpuAccess();
        return w.buffers[i].?.image();
    }

    /// Applies rounded window corners and drop-shadow margin to the current
    /// back buffer for the `repainted` viewports (or the entire window if `null`).
    pub fn finishFrame(w: *WaylandWindow, repainted: ?[]const gfx.Viewport) void {
        const i = w.back orelse return;
        const b = &w.buffers[i].?;
        if (b.margin > 0) {
            b.renderShadowMargin();
            b.applyRoundedCorners(if (b.drawn == 0) null else repainted);
        }
        w.frame_corners_applied = true;
    }

    /// How many frames ago the buffer `beginFrame` gave was last drawn: 1
    /// if in the frame before, 0 if never.
    pub fn bufferAge(w: *const WaylandWindow) u32 {
        const i = w.back orelse return 0;
        const b = &w.buffers[i].?;
        if (b.drawn == 0) return 0;
        return @intCast(@min(w.frames + 1 - b.drawn, std.math.maxInt(u32)));
    }

    pub fn show(w: *WaylandWindow) !void {
        return w.showDamaged(null);
    }

    pub fn showDamaged(w: *WaylandWindow, damage: ?[]const gfx.Viewport) !void {
        const i = w.back orelse return error.NoFrameBegun;
        try w.showBuffer(i, damage);
        w.back = null;
    }

    fn showBuffer(w: *WaylandWindow, i: usize, damage: ?[]const gfx.Viewport) !void {
        while (w.vsync and w.frame_pending) {
            try w.conn.dispatch();
            if (w.suspended) w.releaseSpareBuffers();
        }
        const b = &w.buffers[i].?;
        if (!w.frame_corners_applied) {
            if (b.margin > 0) {
                b.renderShadowMargin();
                b.applyRoundedCorners(if (b.drawn == 0) null else damage);
            }
            w.frame_corners_applied = true;
        }
        b.endCpuAccess();
        const s = @max(b.scale, 1);
        const m_logical = b.margin / s;
        const cw_logical = (if (b.content_w > 0) b.content_w else b.width) / s;
        const ch_logical = (if (b.content_h > 0) b.content_h else b.height) / s;
        const geom_key = [3]u32{ m_logical, cw_logical, ch_logical };
        if (w.last_geometry == null or !std.meta.eql(w.last_geometry.?, geom_key)) {
            w.last_geometry = geom_key;
            var gm = try w.xdg_surface.request(p.xdg_surface.request.set_window_geometry);
            gm.int(@intCast(m_logical)).int(@intCast(m_logical)).int(@intCast(cw_logical)).int(@intCast(ch_logical)).end();
            if (m_logical > 0) {
                const outset: i32 = @intFromFloat(resize_outset);
                const rx: i32 = @as(i32, @intCast(m_logical)) - outset;
                const ry: i32 = @as(i32, @intCast(m_logical)) - outset;
                const rw: i32 = @as(i32, @intCast(cw_logical)) + 2 * outset;
                const rh: i32 = @as(i32, @intCast(ch_logical)) + 2 * outset;
                const in_reg = try w.conn.newObject(null);
                var rm = try w.compositor.request(p.wl_compositor.request.create_region);
                rm.uint(in_reg.id).end();
                rm = try in_reg.request(p.wl_region.request.add);
                rm.int(rx).int(ry).int(rw).int(rh).end();
                rm = try w.surface.request(p.wl_surface.request.set_input_region);
                rm.uint(in_reg.id).end();
                rm = try in_reg.request(p.wl_region.request.destroy);
                rm.end();
                w.conn.forget(in_reg.id);

                const r_i: i32 = @intFromFloat(@ceil(corner_radius));
                const cw_i: i32 = @intCast(cw_logical);
                const ch_i: i32 = @intCast(ch_logical);
                const m_i: i32 = @intCast(m_logical);
                if (cw_i > 2 * r_i and ch_i > 2 * r_i) {
                    const op_reg = try w.conn.newObject(null);
                    rm = try w.compositor.request(p.wl_compositor.request.create_region);
                    rm.uint(op_reg.id).end();
                    rm = try op_reg.request(p.wl_region.request.add);
                    rm.int(m_i + r_i).int(m_i).int(cw_i - 2 * r_i).int(ch_i).end();
                    rm = try op_reg.request(p.wl_region.request.add);
                    rm.int(m_i).int(m_i + r_i).int(cw_i).int(ch_i - 2 * r_i).end();
                    rm = try w.surface.request(p.wl_surface.request.set_opaque_region);
                    rm.uint(op_reg.id).end();
                    rm = try op_reg.request(p.wl_region.request.destroy);
                    rm.end();
                    w.conn.forget(op_reg.id);
                } else {
                    rm = try w.surface.request(p.wl_surface.request.set_opaque_region);
                    rm.uint(0).end();
                }
            } else {
                var rm = try w.surface.request(p.wl_surface.request.set_input_region);
                rm.uint(0).end();
                const op_reg = try w.conn.newObject(null);
                rm = try w.compositor.request(p.wl_compositor.request.create_region);
                rm.uint(op_reg.id).end();
                rm = try op_reg.request(p.wl_region.request.add);
                rm.int(0).int(0).int(@intCast(cw_logical)).int(@intCast(ch_logical)).end();
                rm = try w.surface.request(p.wl_surface.request.set_opaque_region);
                rm.uint(op_reg.id).end();
                rm = try op_reg.request(p.wl_region.request.destroy);
                rm.end();
                w.conn.forget(op_reg.id);
            }
        }
        var m = try w.surface.request(p.wl_surface.request.set_buffer_scale);
        m.int(@intCast(b.scale)).end();
        m = try w.surface.request(p.wl_surface.request.attach);
        m.uint(b.proxy.id).int(0).int(0).end();
        const m_px: i32 = @intCast(b.margin);
        if (b.drawn == 0 or damage == null) {
            m = try w.surface.request(p.wl_surface.request.damage_buffer);
            m.int(0).int(0).int(@intCast(b.width)).int(@intCast(b.height)).end();
        } else if (damage) |rects| {
            for (rects) |r| {
                m = try w.surface.request(p.wl_surface.request.damage_buffer);
                m.int(r.x + m_px).int(r.y + m_px).int(@intCast(r.width)).int(@intCast(r.height)).end();
            }
        }
        if (b.syncobj_timeline.id != 0) {
            if (w.syncobj_surface == null) if (w.drm_syncobj_manager) |mgr| {
                const ss = try w.conn.newObject(null);
                var sm = try mgr.request(p.wp_linux_drm_syncobj_manager_v1.request.get_surface);
                sm.uint(ss.id).uint(w.surface.id).end();
                w.syncobj_surface = ss;
            };
            if (w.syncobj_surface != null) {
                // The CPU has finished drawing: the buffer can be read now.
                var handle = b.syncobj_handle;
                var pt = b.syncobj_point + 1;
                if (b.drm.?.SyncobjTimelineSignal.?(b.drm_fd, &handle, &pt, 1) != 0) {
                    // An acquire point that is never signalled would hang
                    // the surface: go without explicit synchronization.
                    w.stopSyncobj();
                }
            }
            if (w.syncobj_surface) |ss| {
                const acquire_pt = b.syncobj_point + 1;
                const release_pt = acquire_pt + 1;
                b.syncobj_point = release_pt;
                b.release_point = release_pt;

                var sm = try ss.request(p.wp_linux_drm_syncobj_surface_v1.request.set_acquire_point);
                sm.uint(b.syncobj_timeline.id).uint(@intCast(acquire_pt >> 32)).uint(@truncate(acquire_pt)).end();
                sm = try ss.request(p.wp_linux_drm_syncobj_surface_v1.request.set_release_point);
                sm.uint(b.syncobj_timeline.id).uint(@intCast(release_pt >> 32)).uint(@truncate(release_pt)).end();
            }
        }
        if (w.vsync) {
            const cb = try w.conn.newObject(.{ .ptr = w, .handler = frameDone });
            m = try w.surface.request(p.wl_surface.request.frame);
            m.uint(cb.id).end();
            if (w.fifo) |fifo| {
                if (w.fifo_barrier_pending) {
                    m = try fifo.request(p.wp_fifo_v1.request.wait_barrier);
                    m.end();
                }
                m = try fifo.request(p.wp_fifo_v1.request.set_barrier);
                m.end();
                w.fifo_barrier_pending = true;
            }
        }
        if (w.commit_timer) |timer| if (w.target_ns) |target_ns| {
            // Not before half a refresh ahead of the time it is drawn
            // for, so that it shows at the refresh nearest that time
            // (not the one after, if the time is a little late).
            if (w.refresh_ns > 0 and w.presentation_clock_id == p.wp_presentation.clock.monotonic) {
                const earliest_ns = target_ns -| w.refresh_ns / 2;
                if (nowNs() < earliest_ns) {
                    const secs = earliest_ns / std.time.ns_per_s;
                    const nsec: u32 = @intCast(earliest_ns % std.time.ns_per_s);
                    m = try timer.request(p.wp_commit_timer_v1.request.set_timestamp);
                    m.uint(@intCast(secs >> 32)).uint(@truncate(secs)).uint(nsec).end();
                }
            }
        };
        w.target_ns = null;
        if (w.presentation) |pres| {
            const fb = try w.conn.newObject(.{ .ptr = w, .handler = feedbackEvent });
            m = try pres.request(p.wp_presentation.request.feedback);
            m.uint(w.surface.id).uint(fb.id).end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        b.busy = true;
        w.frames += 1;
        b.drawn = w.frames;
        if (w.vsync) w.frame_pending = true;
    }

    pub fn takeInput(w: *WaylandWindow) []const InputEvent {
        defer w.input_len = 0;
        return w.input[0..w.input_len];
    }

    fn pickBack(w: *WaylandWindow) !usize {
        const s = @max(w.scale, 1);
        const m_logical = w.frameMargin();
        const cw = w.width * s;
        const ch = w.height * s;
        const m_px = m_logical * s;
        const bw = cw + 2 * m_px;
        const bh = ch + 2 * m_px;
        while (true) {
            var empty: ?usize = null;
            var stale: ?usize = null;
            var syncobj_wait_idx: ?usize = null;
            for (&w.buffers, 0..) |*slot, i| {
                if (slot.*) |*b| {
                    if (!b.isReady()) {
                        if (b.release_point > 0) {
                            if (syncobj_wait_idx == null or b.drawn < w.buffers[syncobj_wait_idx.?].?.drawn) {
                                syncobj_wait_idx = i;
                            }
                        }
                        continue;
                    }
                    if (b.width == bw and b.height == bh and b.content_w == cw and b.content_h == ch and b.margin == m_px and b.scale == s) return i;
                    stale = i;
                } else empty = i;
            }
            if (stale) |i| {
                w.freeBuffer(&w.buffers[i].?, &w.buffers[i]);
                empty = i;
            }
            if (empty) |i| {
                w.buffers[i] = try w.allocBuffer(i);
                return i;
            }
            if (syncobj_wait_idx) |i| {
                _ = w.buffers[i].?.waitReady(16 * std.time.ns_per_ms);
                _ = try w.conn.dispatchPending();
            } else {
                try w.conn.dispatch();
            }
        }
    }

    pub fn releaseSpareBuffers(w: *WaylandWindow) void {
        for (&w.buffers, 0..) |*slot, i| if (slot.*) |*b| {
            if (!b.isReady() or w.back == i) continue;
            w.freeBuffer(b, slot);
        };
    }

    fn allocBuffer(w: *WaylandWindow, slot: usize) !Buffer {
        const s = @max(w.scale, 1);
        const m_logical = w.frameMargin();
        const cw = w.width * s;
        const ch = w.height * s;
        const m_px = m_logical * s;
        const bw = cw + 2 * m_px;
        const bh = ch + 2 * m_px;
        if (w.usingDmabuf()) {
            if (w.allocDmabufBuffer(slot, bw, bh, cw, ch, m_px, s)) |buf| {
                return buf;
            } else |err| {
                if (w.shm.id == 0) return err;
                // wl_shm buffers cannot be explicitly synchronized, and the
                // dmabuf buffers belong to the device being closed.
                w.stopSyncobj();
                for (&w.buffers, 0..) |*other, i| if (i != slot) if (other.*) |*b| if (b.bo != null) w.freeBuffer(b, other);
                if (w.dmabuf_dev) |*dev| dev.close();
                w.dmabuf_dev = null;
                w.updateExtensions();
            }
        }
        return w.allocShmBuffer(slot, bw, bh, cw, ch, m_px, s);
    }

    fn allocDmabufBuffer(w: *WaylandWindow, slot: usize, bw: u32, bh: u32, cw: u32, ch: u32, m_px: u32, s: u32) !Buffer {
        const dmabuf = w.dmabuf orelse return error.NoDmabuf;
        const dev = &(w.dmabuf_dev orelse return error.NoDmabuf);
        const fmt: u32 = if ((m_px > 0 and w.dmabuf_argb8888) or !w.dmabuf_xrgb8888)
            p.fourcc.argb8888
        else
            p.fourcc.xrgb8888;
        const alloc = try dev.alloc(bw, bh, fmt);
        errdefer dev.gbm.bo_destroy(alloc.bo);
        var fd_sent = false;
        errdefer if (!fd_sent) {
            _ = linux.close(alloc.dmabuf_fd);
        };

        const params = try w.conn.newObject(null);
        var m = try dmabuf.request(p.zwp_linux_dmabuf_v1.request.create_params);
        m.uint(params.id).end();

        const mod = if (alloc.modifier != 0x00ffffffffffffff) alloc.modifier else p.modifier.linear;
        m = try params.request(p.zwp_linux_buffer_params_v1.request.add);
        m.fd(alloc.dmabuf_fd).uint(0).uint(alloc.offset).uint(alloc.stride).uint(@intCast(mod >> 32)).uint(@truncate(mod)).end();
        fd_sent = true;

        const proxy = try w.conn.newObject(.{ .ptr = &w.buffers[slot], .handler = bufferEvent });
        m = try params.request(p.zwp_linux_buffer_params_v1.request.create_immed);
        m.uint(proxy.id).int(@intCast(bw)).int(@intCast(bh)).uint(fmt).uint(0).end();

        m = try params.request(p.zwp_linux_buffer_params_v1.request.destroy);
        m.end();
        w.conn.forget(params.id);

        var syncobj_handle: u32 = 0;
        var syncobj_timeline: client.Proxy = .{};
        defer if (syncobj_timeline.id == 0 and w.usingDrmSyncobj()) {
            // Every buffer needs a timeline while explicit synchronization
            // is on (or committing it is a protocol error).
            w.stopSyncobj();
        };
        if (w.usingDrmSyncobj()) if (w.drm_syncobj_manager) |mgr| {
            var handle: u32 = 0;
            if (dev.drm.SyncobjCreate.?(dev.drm_fd, 0, &handle) == 0) {
                var obj_fd: c_int = -1;
                if (dev.drm.SyncobjHandleToFD.?(dev.drm_fd, handle, &obj_fd) == 0 and obj_fd >= 0) {
                    if (w.conn.newObject(null)) |tl| {
                        if (mgr.request(p.wp_linux_drm_syncobj_manager_v1.request.import_timeline)) |tm0| {
                            var tm = tm0;
                            tm.uint(tl.id).fd(obj_fd).end();
                            syncobj_handle = handle;
                            syncobj_timeline = tl;
                        } else |_| {
                            w.conn.forget(tl.id);
                            _ = linux.close(obj_fd);
                            _ = dev.drm.SyncobjDestroy.?(dev.drm_fd, handle);
                        }
                    } else |_| {
                        _ = linux.close(obj_fd);
                        _ = dev.drm.SyncobjDestroy.?(dev.drm_fd, handle);
                    }
                } else {
                    _ = dev.drm.SyncobjDestroy.?(dev.drm_fd, handle);
                }
            }
        };

        return .{
            .bo = alloc.bo,
            .gbm = dev.gbm,
            .drm_fd = dev.drm_fd,
            .drm = dev.drm,
            .syncobj_handle = syncobj_handle,
            .syncobj_timeline = syncobj_timeline,
            .proxy = proxy,
            .width = bw,
            .height = bh,
            .stride_words = alloc.stride / 4,
            .content_w = cw,
            .content_h = ch,
            .margin = m_px,
            .scale = s,
        };
    }

    fn allocShmBuffer(w: *WaylandWindow, slot: usize, bw: u32, bh: u32, cw: u32, ch: u32, m_px: u32, s: u32) !Buffer {
        const stride = bw * 4;
        const size: usize = @as(usize, stride) * @as(usize, bh);
        const rc = linux.memfd_create("facet-shm", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.OutOfMemory;
        const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) return error.OutOfMemory;
        const pixels: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(map_rc))[0..size];
        errdefer _ = linux.munmap(pixels.ptr, size);

        const pool = try w.conn.newObject(null);
        var m = try w.shm.request(p.wl_shm.request.create_pool);
        m.uint(pool.id).fd(fd).int(@intCast(size)).end();

        const proxy = try w.conn.newObject(.{ .ptr = &w.buffers[slot], .handler = bufferEvent });
        m = try pool.request(p.wl_shm_pool.request.create_buffer);
        const fmt: u32 = if (m_px > 0) p.wl_shm.format.argb8888 else p.wl_shm.format.xrgb8888;
        m.uint(proxy.id).int(0).int(@intCast(bw)).int(@intCast(bh)).int(@intCast(stride)).uint(fmt).end();

        return .{
            .pixels = pixels,
            .pool = pool,
            .proxy = proxy,
            .width = bw,
            .height = bh,
            .stride_words = bw,
            .content_w = cw,
            .content_h = ch,
            .margin = m_px,
            .scale = s,
        };
    }

    /// Frees the buffer. The compositor may still be reading it: it keeps
    /// its own reference to the memory, and the timeline's points stay set.
    fn freeBuffer(w: *WaylandWindow, b: *Buffer, slot: *?Buffer) void {
        b.endCpuAccess();
        if (b.syncobj_timeline.id != 0) {
            if (b.syncobj_timeline.request(p.wp_linux_drm_syncobj_timeline_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(b.syncobj_timeline.id);
            if (b.drm) |drm| if (drm.SyncobjDestroy) |destroy_fn| {
                _ = destroy_fn(b.drm_fd, b.syncobj_handle);
            };
        }
        if (b.proxy.request(p.wl_buffer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(b.proxy.id);
        if (b.pool.id != 0) {
            if (b.pool.request(p.wl_shm_pool.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(b.pool.id);
        }
        if (b.bo) |bo| {
            if (b.gbm) |gbm| gbm.bo_destroy(bo);
        } else if (b.pixels.len > 0) {
            _ = linux.munmap(@alignCast(b.pixels.ptr), b.pixels.len);
        }
        slot.* = null;
    }

    fn bufferEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const slot: *?Buffer = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_buffer.event.release) if (slot.*) |*b| {
            b.busy = false;
        };
    }

    fn frameDone(ptr: ?*anyopaque, d: *client.Display, id: u32, _: u16, _: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        d.forget(id);
        w.frame_pending = false;
    }

    fn surfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_surface.event.preferred_buffer_scale) {
            const factor = r.int() catch return;
            if (factor > 0) {
                const new_scale: u32 = @intCast(factor);
                w.scale = new_scale;
            }
        }
    }

    fn presentationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wp_presentation.event.clock_id) {
            w.presentation_clock_id = r.uint() catch return;
        }
    }

    fn feedbackEvent(ptr: ?*anyopaque, d: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wp_presentation_feedback.event.sync_output => {
                _ = r.uint() catch return;
            },
            p.wp_presentation_feedback.event.presented => {
                defer d.forget(id);
                const tv_sec_hi = r.uint() catch return;
                const tv_sec_lo = r.uint() catch return;
                const tv_nsec = r.uint() catch return;
                const refresh = r.uint() catch return;
                const seq_hi = r.uint() catch return;
                const seq_lo = r.uint() catch return;
                const flags = r.uint() catch return;
                const secs = (@as(u64, tv_sec_hi) << 32) | tv_sec_lo;
                w.presented_ns = secs * std.time.ns_per_s + tv_nsec;
                if (refresh > 0) w.refresh_ns = refresh;
                w.presentation_seq = (@as(u64, seq_hi) << 32) | seq_lo;
                w.presentation_flags = flags;
                w.presented_frames += 1;
            },
            p.wp_presentation_feedback.event.discarded => {
                d.forget(id);
                w.discarded_frames += 1;
            },
            else => {},
        }
    }

    fn surfaceToContent(w: *const WaylandWindow, pos: [2]f32) [2]f32 {
        const m: f32 = @floatFromInt(w.frameMargin());
        return .{ pos[0] - m, pos[1] - m };
    }

    fn isInsideContent(w: *const WaylandWindow, pos: [2]f32) bool {
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        if (pos[0] < 0 or pos[1] < 0 or pos[0] >= width or pos[1] >= height) return false;
        if (w.hasClientDecorations()) {
            const hx = @max(width * 0.5 - corner_radius, 0.0);
            const hy = @max(height * 0.5 - corner_radius, 0.0);
            if (sdfRoundedBox(pos[0] - width * 0.5, pos[1] - height * 0.5, hx, hy, corner_radius) > 0.0) return false;
        }
        return true;
    }

    fn onDragEnter(ptr: ?*anyopaque, pos: [2]f32, _: ?[]const u8) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drag_enter = w.surfaceToContent(pos) });
    }

    fn onDragMotion(ptr: ?*anyopaque, pos: [2]f32) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const cpos = w.surfaceToContent(pos);
        if (w.input_len > 0 and w.input[w.input_len - 1] == .drag_motion) {
            w.input[w.input_len - 1] = .{ .drag_motion = cpos };
            return;
        }
        w.pushInput(.{ .drag_motion = cpos });
    }

    fn onDragLeave(ptr: ?*anyopaque) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.drag_leave);
    }

    fn onDragDrop(ptr: ?*anyopaque, pos: [2]f32, _: []const u8, _: []const u8, _: u32) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drop = w.surfaceToContent(pos) });
    }

    fn textInputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_text_input_v3.event.enter => {
                _ = r.uint() catch return;
                w.text_input_entered = true;
                if (w.text_input_enabled) if (w.text_input) |ti| {
                    w.sendTextInputState(ti, true);
                };
            },
            p.zwp_text_input_v3.event.leave => {
                _ = r.uint() catch return;
                w.text_input_entered = false;
                w.text_input_pending_preedit = null;
                w.text_input_pending_commit = null;
                w.text_input_pending_delete = null;
            },
            p.zwp_text_input_v3.event.preedit_string => {
                const text = (r.string() catch return) orelse "";
                const begin = r.int() catch return;
                const end = r.int() catch return;
                var pre: @TypeOf(w.text_input_pending_preedit.?) = .{ .cursor_begin = begin, .cursor_end = end };
                const n: u8 = @intCast(@min(text.len, pre.buf.len));
                @memcpy(pre.buf[0..n], text[0..n]);
                pre.len = n;
                w.text_input_pending_preedit = pre;
            },
            p.zwp_text_input_v3.event.commit_string => {
                const text = (r.string() catch return) orelse "";
                var com: @TypeOf(w.text_input_pending_commit.?) = .{};
                const n: u8 = @intCast(@min(text.len, com.buf.len));
                @memcpy(com.buf[0..n], text[0..n]);
                com.len = n;
                w.text_input_pending_commit = com;
            },
            p.zwp_text_input_v3.event.delete_surrounding_text => {
                const before = r.uint() catch return;
                const after = r.uint() catch return;
                w.text_input_pending_delete = .{ .before_length = before, .after_length = after };
            },
            p.zwp_text_input_v3.event.done => {
                _ = r.uint() catch return;
                if (w.text_input_pending_delete) |del| {
                    w.text_input_pending_delete = null;
                    w.pushInput(.{ .text_delete_surrounding = .{ .before_length = del.before_length, .after_length = del.after_length } });
                }
                if (w.text_input_pending_commit) |com| {
                    w.text_input_pending_commit = null;
                    if (com.len > 0) {
                        var ev: InputEvent = .{ .text_commit = .{ .len = com.len } };
                        @memcpy(ev.text_commit.buf[0..com.len], com.buf[0..com.len]);
                        w.pushInput(ev);
                    }
                }
                if (w.text_input_pending_preedit) |pre| {
                    w.text_input_pending_preedit = null;
                    w.text_input_has_preedit = pre.len > 0;
                    var ev: InputEvent = .{ .text_preedit = .{ .len = pre.len, .cursor_begin = pre.cursor_begin, .cursor_end = pre.cursor_end } };
                    @memcpy(ev.text_preedit.buf[0..pre.len], pre.buf[0..pre.len]);
                    w.pushInput(ev);
                } else if (w.text_input_has_preedit) {
                    w.text_input_has_preedit = false;
                    w.pushInput(.{ .text_preedit = .{} });
                }
            },
            else => {},
        }
    }

    fn pushInput(w: *WaylandWindow, e: InputEvent) void {
        if (e == .motion and w.input_len > 0 and w.input[w.input_len - 1] == .motion) {
            w.input[w.input_len - 1] = e;
            return;
        }
        if (e == .touch_motion and w.input_len > 0) switch (w.input[w.input_len - 1]) {
            .touch_motion => |last| if (last.id == e.touch_motion.id) {
                w.input[w.input_len - 1] = e;
                return;
            },
            else => {},
        };
        if (w.input_len == w.input.len) return;
        w.input[w.input_len] = e;
        w.input_len += 1;
    }

    fn seatEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_seat.event.capabilities) return;
        const caps = r.uint() catch return;
        if (caps & p.wl_seat.capability.pointer != 0 and w.pointer == null) {
            const pointer = d.newObject(.{ .ptr = w, .handler = pointerEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_pointer) catch return;
            m.uint(pointer.id).end();
            w.pointer = pointer;
            if (w.cursor_shape_manager) |manager| {
                const device = d.newObject(null) catch return;
                m = manager.request(p.wp_cursor_shape_manager_v1.request.get_pointer) catch return;
                m.uint(device.id).uint(pointer.id).end();
                w.cursor_device = device;
            }
            if (w.relative_pointer_manager) |manager| {
                const rel = d.newObject(.{ .ptr = w, .handler = relativeEvent }) catch return;
                m = manager.request(p.zwp_relative_pointer_manager_v1.request.get_relative_pointer) catch return;
                m.uint(rel.id).uint(pointer.id).end();
                w.relative_pointer = rel;
            }
        }
        if (caps & p.wl_seat.capability.touch != 0 and w.touch == null) {
            const touch = d.newObject(.{ .ptr = w, .handler = touchEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_touch) catch return;
            m.uint(touch.id).end();
            w.touch = touch;
        }
        if (caps & p.wl_seat.capability.keyboard != 0 and w.keyboard == null) {
            const keyboard = d.newObject(.{ .ptr = w, .handler = keyboardEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_keyboard) catch return;
            m.uint(keyboard.id).end();
            w.keyboard = keyboard;
        }
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_pointer.event.enter, p.wl_pointer.event.motion => {
                const first = r.uint() catch return;
                if (opcode == p.wl_pointer.event.enter) {
                    _ = r.uint() catch return;
                    w.enter_serial = first;
                    w.buttons_down = 0;
                    w.cursor_shape = p.wp_cursor_shape_device_v1.shape.default;
                }
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                w.pointer_pos = w.surfaceToContent(.{ @floatCast(x), @floatCast(y) });
                w.updateCursor();
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_pointer.button_state.pressed;
                if (pressed) {
                    w.press_serial = serial;
                    w.clipboard.serial = serial;
                } else {
                    w.press_serial = 0;
                }
                if (pressed and code == p.input.btn_left) {
                    const edges = w.edgesAt(w.pointer_pos);
                    if (edges != 0) if (w.seat) |seat| {
                        var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                        m.uint(seat.id).uint(serial).uint(edges).end();
                        w.conn.flush() catch {};
                        return;
                    };
                }
                if (pressed and w.buttons_down == 0 and !w.isInsideContent(w.pointer_pos)) return;
                const bit = @as(u32, 1) << @intCast(@min(code -% p.input.btn_left, 31));
                w.buttons_down = if (pressed) w.buttons_down | bit else w.buttons_down & ~bit;
                if (!pressed and w.buttons_down == 0) w.updateCursor();
                w.pushInput(.{ .button = .{ .pos = w.pointer_pos, .code = code, .pressed = pressed } });
            },
            p.wl_pointer.event.axis => {
                _ = r.uint() catch return;
                const axis = r.uint() catch return;
                const value: f32 = @floatCast(r.fixed() catch return);
                const vertical = axis == p.wl_pointer.axis.vertical_scroll;
                w.pushInput(.{ .scroll = .{ .pos = w.pointer_pos, .dx = if (vertical) 0 else value, .dy = if (vertical) value else 0 } });
            },
            p.wl_pointer.event.leave => {
                w.buttons_down = 0;
                w.press_serial = 0;
                w.cursor_shape = null;
                w.pushInput(.leave);
            },
            else => {},
        }
    }

    fn touchEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_touch.event.down => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const pos = w.surfaceToContent(.{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) });
                w.press_serial = serial;
                w.clipboard.serial = serial;
                const edges = w.edgesAt(pos);
                if (edges != 0) if (w.seat) |seat| {
                    var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                    m.uint(seat.id).uint(serial).uint(edges).end();
                    w.conn.flush() catch {};
                    return;
                };
                if (!w.isInsideContent(pos)) return;
                w.pushInput(.{ .touch_down = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.motion => {
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const pos = w.surfaceToContent(.{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) });
                w.pushInput(.{ .touch_motion = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.up => {
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                w.press_serial = 0;
                w.pushInput(.{ .touch_up = @bitCast(r.uint() catch return) });
            },
            p.wl_touch.event.cancel => {
                w.press_serial = 0;
                w.pushInput(.touch_cancel);
            },
            else => {},
        }
    }

    pub fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_keyboard.event.keymap => {
                _ = r.uint() catch return;
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                const size = r.uint() catch return;
                if (keyboardFromKeymap(fd, size)) |k| w.layout = k;
            },
            p.wl_keyboard.event.key => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_keyboard.key_state.pressed;
                if (pressed) w.clipboard.serial = serial;
                if (code < 256) w.keys_down.setValue(code, pressed);
                if (pressed) {
                    if (!isModifierKey(code) and w.repeat_rate > 0) {
                        w.repeat = .{
                            .code = code,
                            .next_ns = nowNs() + @as(u64, w.repeat_delay_ms) * std.time.ns_per_ms,
                        };
                    }
                } else if (w.repeat) |rep| {
                    if (rep.code == code) w.repeat = null;
                }
                w.pushInput(.{ .key = .{ .code = code, .pressed = pressed } });
            },
            p.wl_keyboard.event.leave => {
                w.repeat = null;
                var it = w.keys_down.iterator(.{});
                while (it.next()) |code| {
                    w.pushInput(.{ .key = .{ .code = @intCast(code), .pressed = false } });
                }
                w.keys_down = .empty;
            },
            p.wl_keyboard.event.repeat_info => {
                const rate = r.int() catch return;
                const delay = r.int() catch return;
                w.repeat_rate = @intCast(@max(rate, 0));
                w.repeat_delay_ms = @intCast(@max(delay, 0));
                if (w.repeat_rate == 0) w.repeat = null;
            },
            else => {},
        }
    }

    fn isModifierKey(code: u32) bool {
        return switch (code) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
    }

    fn wmBaseEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_wm_base.event.ping) return;
        const serial = r.uint() catch return;
        var m = w.wm_base.request(p.xdg_wm_base.request.pong) catch return;
        m.uint(serial).end();
    }

    fn xdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.xdg_surface.event.configure) w.pending_serial = r.uint() catch return;
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.xdg_toplevel.event.configure => {
                w.next_size = .{ r.int() catch 0, r.int() catch 0 };
                const states = r.array() catch &.{};
                var suspended = false;
                var maximized = false;
                var fullscreen = false;
                var tiled = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                    p.xdg_toplevel.state.suspended => suspended = true,
                    p.xdg_toplevel.state.maximized => maximized = true,
                    p.xdg_toplevel.state.fullscreen => fullscreen = true,
                    p.xdg_toplevel.state.tiled_left,
                    p.xdg_toplevel.state.tiled_right,
                    p.xdg_toplevel.state.tiled_top,
                    p.xdg_toplevel.state.tiled_bottom,
                    => tiled = true,
                    else => {},
                };
                if (suspended) w.repeat = null;
                if (w.maximized != maximized or w.fullscreen != fullscreen or w.tiled != tiled) {
                    w.decoration_changed = true;
                }
                w.suspended = suspended;
                w.maximized = maximized;
                w.fullscreen = fullscreen;
                w.tiled = tiled;
            },
            p.xdg_toplevel.event.close => w.closed = true,
            else => {},
        }
    }

    pub fn decorationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.zxdg_toplevel_decoration_v1.event.configure) {
            const mode = r.uint() catch return;
            const ssd = mode == p.zxdg_toplevel_decoration_v1.mode.server_side;
            if (w.server_decorations != ssd) {
                w.server_decorations = ssd;
                w.decoration_changed = true;
            }
        }
    }

    pub fn dmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_linux_dmabuf_v1.event.format => {
                const fmt = r.uint() catch return;
                if (fmt == p.fourcc.argb8888) w.dmabuf_argb8888 = true;
                if (fmt == p.fourcc.xrgb8888) w.dmabuf_xrgb8888 = true;
            },
            p.zwp_linux_dmabuf_v1.event.modifier => {
                const fmt = r.uint() catch return;
                const mod_hi = r.uint() catch return;
                const mod_lo = r.uint() catch return;
                const mod = (@as(u64, mod_hi) << 32) | mod_lo;
                if (mod == p.modifier.linear or mod == 0x00ffffffffffffff) {
                    if (fmt == p.fourcc.argb8888) w.dmabuf_argb8888 = true;
                    if (fmt == p.fourcc.xrgb8888) w.dmabuf_xrgb8888 = true;
                }
            },
            else => {},
        }
    }
};

fn keyboardFromKeymap(fd: linux.fd_t, size: u32) ?Keyboard {
    if (size == 0 or size > 1 << 20) return null;
    const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const text = @as([*]const u8, @ptrFromInt(rc))[0..size];
    defer _ = linux.munmap(text.ptr, size);
    return layoutNamed(text);
}

fn layoutNamed(keymap: []const u8) ?Keyboard {
    const key = "xkb_symbols \"";
    const at = std.mem.indexOf(u8, keymap, key) orelse return null;
    const rest = keymap[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return Keyboard.fromCode(rest[0..end]);
}

test "the layout is named in the keymap" {
    try std.testing.expectEqual(Keyboard.gb, layoutNamed("xkb_keymap {\nxkb_symbols \"gb\" {\n").?);
    try std.testing.expect(layoutNamed("xkb_symbols \"pc+us+inet(evdev)\" {") == null);
    try std.testing.expect(layoutNamed("nothing") == null);
}

test "held keys repeat after the delay, except modifiers, and stop on release or leave" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
    };
    var disp: client.Display = undefined;

    const repeat_msg = [_]u32{ 25, 200 };
    var r_info = wire.Reader{ .data = std.mem.sliceAsBytes(&repeat_msg), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.repeat_info, &r_info);
    try std.testing.expectEqual(@as(u32, 25), win.repeat_rate);
    try std.testing.expectEqual(@as(u32, 200), win.repeat_delay_ms);

    const shift_down = [_]u32{ 1, 0, 42, p.wl_keyboard.key_state.pressed };
    var r_shift = wire.Reader{ .data = std.mem.sliceAsBytes(&shift_down), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_shift);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    const a_down = [_]u32{ 2, 0, 30, p.wl_keyboard.key_state.pressed };
    var r_a_down = wire.Reader{ .data = std.mem.sliceAsBytes(&a_down), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_down);
    try std.testing.expectEqual(@as(u32, 30), win.repeat.?.code);
    try std.testing.expectEqual(@as(usize, 1), win.takeInput().len);

    const first_due = win.repeat.?.next_ns;
    win.serviceRepeat(first_due - 1);
    try std.testing.expectEqual(@as(usize, 0), win.takeInput().len);
    try std.testing.expectEqual(@as(?u64, 1), win.repeatTimeoutMs(first_due - 1));

    win.serviceRepeat(first_due);
    const rep1 = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), rep1.len);
    try std.testing.expectEqual(@as(u32, 30), rep1[0].key.code);
    try std.testing.expect(rep1[0].key.pressed);
    try std.testing.expectEqual(first_due + 40 * std.time.ns_per_ms, win.repeat.?.next_ns);

    const a_up = [_]u32{ 3, 0, 30, p.wl_keyboard.key_state.released };
    var r_a_up = wire.Reader{ .data = std.mem.sliceAsBytes(&a_up), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_up);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    const leave_msg = [_]u32{ 4, 1 };
    var r_leave = wire.Reader{ .data = std.mem.sliceAsBytes(&leave_msg), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.leave, &r_leave);
    const left = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqual(@as(u32, 42), left[0].key.code);
    try std.testing.expect(!left[0].key.pressed);
}

test "setMinSize clamps non-maximized window dimensions" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
        .width = 400,
        .height = 300,
        .maximized = false,
        .fullscreen = false,
    };
    // Pre-populate min_size so setMinSize returns before touching the wire connection.
    win.min_size = .{ 640, 480 };
    win.setMinSize(640, 480);
    try std.testing.expectEqual(@as(u32, 640), win.width);
    try std.testing.expectEqual(@as(u32, 480), win.height);
}

test "edgesAt detects resize edges only outside the window content and respects maximized state" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
        .width = 400,
        .height = 300,
        .maximized = false,
        .fullscreen = false,
    };
    // Outer band outside the edges triggers resize.
    try std.testing.expectEqual(@as(u32, edge_left), win.edgesAt(.{ -5, 150 }));
    try std.testing.expectEqual(@as(u32, edge_right), win.edgesAt(.{ 405, 150 }));
    try std.testing.expectEqual(@as(u32, edge_top), win.edgesAt(.{ 200, -5 }));
    try std.testing.expectEqual(@as(u32, edge_bottom), win.edgesAt(.{ 200, 305 }));
    try std.testing.expectEqual(@as(u32, edge_top | edge_left), win.edgesAt(.{ -4, -4 }));
    try std.testing.expectEqual(@as(u32, edge_top | edge_left), win.edgesAt(.{ -4, 10 }));
    // Outside the rounded corner arc at (1, 1) triggers corner resize.
    try std.testing.expectEqual(@as(u32, edge_top | edge_left), win.edgesAt(.{ 1, 1 }));
    // Inside the window content (including 1px inside the border) never triggers resize.
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 1, 150 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 398, 150 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 200, 1 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 200, 298 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 200, 150 }));
    // Beyond resize_outset does not trigger resize.
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -15, 150 }));
    // Maximized, fullscreen, or tiled window has no resize edges and zero frame margin.
    win.maximized = true;
    try std.testing.expect(!win.hasClientDecorations());
    try std.testing.expectEqual(@as(u32, 0), win.frameMargin());
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -5, 150 }));
    win.maximized = false;
    win.tiled = true;
    try std.testing.expect(!win.hasClientDecorations());
    try std.testing.expectEqual(@as(u32, 0), win.frameMargin());
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -5, 150 }));
    // Server-side decorations disable client shadow margin and outer resize edges even when floating.
    win.tiled = false;
    var disp: client.Display = undefined;
    const ssd_msg = [_]u32{p.zxdg_toplevel_decoration_v1.mode.server_side};
    var r_ssd = wire.Reader{ .data = std.mem.sliceAsBytes(&ssd_msg), .c = undefined };
    WaylandWindow.decorationEvent(&win, &disp, 1, p.zxdg_toplevel_decoration_v1.event.configure, &r_ssd);
    try std.testing.expect(win.server_decorations);
    try std.testing.expect(win.decoration_changed);
    try std.testing.expectEqual(window_mod.Decorations.server, win.decorations());
    try std.testing.expect(!win.hasClientDecorations());
    try std.testing.expectEqual(@as(u32, 0), win.frameMargin());
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -5, 150 }));
}

test "Buffer renders drop shadow margin and rounds window corners while exposing inner content Image" {
    const cw: u32 = 80;
    const ch: u32 = 60;
    const m: u32 = shadow_margin;
    const bw: u32 = cw + 2 * m;
    const bh: u32 = ch + 2 * m;
    const bytes = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), @as(usize, bw) * @as(usize, bh) * 4);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);

    var buf: Buffer = .{
        .pixels = bytes,
        .width = bw,
        .height = bh,
        .content_w = cw,
        .content_h = ch,
        .margin = m,
        .scale = 1,
    };

    var img = buf.image();
    try std.testing.expectEqual(cw, img.width);
    try std.testing.expectEqual(ch, img.height);
    try std.testing.expectEqual(bw, img.rowStride());

    // Clear the content image to opaque white.
    img.clear(0xffffffff);
    buf.renderShadowMargin();
    buf.applyRoundedCorners(null);

    const words = std.mem.bytesAsSlice(u32, bytes);
    // Center of the content area remains opaque white.
    const center = words[@as(usize, m + ch / 2) * bw + (m + cw / 2)];
    try std.testing.expectEqual(@as(u32, 0xffffffff), center);

    // Extreme top-left corner of the content box (outside the 12px radius arc) is clipped to shadow (not white).
    const corner_px = words[@as(usize, m) * bw + m];
    try std.testing.expect((corner_px & 0x00ffffff) == 0);

    // Just below the bottom edge of the window has non-zero drop shadow alpha.
    const shadow_below = words[@as(usize, m + ch + 3) * bw + (m + cw / 2)];
    try std.testing.expect((shadow_below >> 24) > 0);
    try std.testing.expect((shadow_below & 0x00ffffff) == 0);
}

test "WaylandWindow prefers linux_dmabuf over wl_shm when zwp_linux_dmabuf_v1 and DmaBufDevice are available" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
    };
    try std.testing.expectEqual(window_mod.BufferTransport.wl_shm, win.bufferTransport());

    var disp: client.Display = undefined;
    const mod_msg = [_]u32{ p.fourcc.argb8888, 0, 0 };
    var r_mod = wire.Reader{ .data = std.mem.sliceAsBytes(&mod_msg), .c = undefined };
    WaylandWindow.dmabufEvent(&win, &disp, 1, p.zwp_linux_dmabuf_v1.event.modifier, &r_mod);
    try std.testing.expect(win.dmabuf_argb8888);

    const fmt_msg = [_]u32{p.fourcc.xrgb8888};
    var r_fmt = wire.Reader{ .data = std.mem.sliceAsBytes(&fmt_msg), .c = undefined };
    WaylandWindow.dmabufEvent(&win, &disp, 1, p.zwp_linux_dmabuf_v1.event.format, &r_fmt);
    try std.testing.expect(win.dmabuf_xrgb8888);

    if (DmaBufDevice.open()) |dev_val| {
        var dev = dev_val;
        defer dev.close();
        win.dmabuf = .{ .id = 10 };
        win.dmabuf_dev = dev;
        try std.testing.expectEqual(window_mod.BufferTransport.linux_dmabuf, win.bufferTransport());

        const alloc = try dev.alloc(64, 48, p.fourcc.argb8888);
        defer {
            _ = linux.close(alloc.dmabuf_fd);
            dev.gbm.bo_destroy(alloc.bo);
        }
        try std.testing.expect(alloc.dmabuf_fd >= 0);
        try std.testing.expect(alloc.stride >= 64 * 4);
        var buf: Buffer = .{
            .bo = alloc.bo,
            .gbm = dev.gbm,
            .width = 64,
            .height = 48,
            .stride_words = alloc.stride / 4,
        };
        try buf.beginCpuAccess();
        var img = buf.image();
        img.clear(0xff112233);
        try std.testing.expectEqual(@as(u32, 0xff112233), img.at(0, 0));
        buf.endCpuAccess();
    }
}

test "WaylandWindow reports active Wayland extensions, synchronization protocols, and presentation refresh rate" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
        .compositor = .{ .id = 2 },
        .shm = .{ .id = 3 },
        .wm_base = .{ .id = 4 },
        .presentation = .{ .id = 5 },
        .fifo_manager = .{ .id = 6 },
        .fifo = .{ .id = 7 },
        .commit_timing_manager = .{ .id = 8 },
        .commit_timer = .{ .id = 9 },
        .drm_syncobj_manager = .{ .id = 10 },
        .syncobj_surface = .{ .id = 11 },
    };
    win.updateExtensions();

    try std.testing.expect(win.vsync);
    try std.testing.expectEqual(window_mod.BufferSync.linux_drm_syncobj_v1, win.bufferSync());
    const fs = win.frameSync();
    try std.testing.expect(fs.vsync);
    try std.testing.expect(fs.frame_callback);
    try std.testing.expect(fs.presentation_time);
    try std.testing.expect(fs.fifo_v1);
    try std.testing.expect(fs.commit_timing_v1);

    const exts = win.extensions();
    try std.testing.expectEqual(@as(usize, 5), exts.len);
    var has_fifo = false;
    var has_commit_timing = false;
    var has_syncobj = false;
    var has_presentation = false;
    for (exts) |ext| {
        if (std.mem.eql(u8, ext, p.wp_fifo_manager_v1.name)) has_fifo = true;
        if (std.mem.eql(u8, ext, p.wp_commit_timing_manager_v1.name)) has_commit_timing = true;
        if (std.mem.eql(u8, ext, p.wp_linux_drm_syncobj_manager_v1.name)) has_syncobj = true;
        if (std.mem.eql(u8, ext, p.wp_presentation.name)) has_presentation = true;
    }
    try std.testing.expect(has_fifo);
    try std.testing.expect(has_commit_timing);
    try std.testing.expect(has_syncobj);
    try std.testing.expect(has_presentation);

    var disp: client.Display = .{ .gpa = std.testing.allocator, .conn = undefined };
    // Simulate wp_presentation_feedback.presented with 16_666_666 ns refresh (~60 Hz)
    const presented_msg = [_]u32{ 0, 1, 500_000_000, 16_666_666, 0, 1, p.wp_presentation_feedback.kind.vsync };
    var r_pres = wire.Reader{ .data = std.mem.sliceAsBytes(&presented_msg), .c = undefined };
    WaylandWindow.feedbackEvent(&win, &disp, 0, p.wp_presentation_feedback.event.presented, &r_pres);
    try std.testing.expectEqual(@as(u64, 16_666_666), win.refresh_ns);
    const hz = win.refreshHz();
    try std.testing.expect(@abs(hz - 60.0) < 0.1);
}

test "WaylandWindow reports no buffer sync for wl_shm and explicit sync only while it has a syncobj surface" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
    };
    try std.testing.expectEqual(window_mod.BufferSync.none, win.bufferSync());
    win.vsync = false;
    try std.testing.expect(!win.frameSync().vsync);
    try std.testing.expect(!win.frameSync().frame_callback);
    win.syncobj_surface = .{ .id = 11 };
    try std.testing.expectEqual(window_mod.BufferSync.linux_drm_syncobj_v1, win.bufferSync());
}
