//! OpenGL 3.3 Core / OpenGL ES 3.0 rendering backend for Facet's 2D `Canvas`.
//!
//! Uses a runtime `GetProcAddress` loader (compatible with `eglGetProcAddress`,
//! `glXGetProcAddress`, `wglGetProcAddress`, SDL, or GLFW) so no C headers or
//! system OpenGL libraries are required at compile time.
//!
//!     var gl = try gfx.opengl.OpenGlRenderer.init(gpa, eglGetProcAddress);
//!     defer gl.deinit();
//!     const target: gfx.opengl.Target = .{ .width = win_w, .height = win_h };
//!     try ui.renderWith(gl.renderer(), &target, null);

const std = @import("std");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");

const Canvas = canvas_mod.Canvas;
const Viewport = renderer_mod.Viewport;

pub const GLenum = c_uint;
pub const GLboolean = u8;
pub const GLbitfield = c_uint;
pub const GLint = c_int;
pub const GLuint = c_uint;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLsizeiptr = isize;
pub const GLintptr = isize;

pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 1;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_DEPTH_TEST: GLenum = 0x0B71;
pub const GL_CULL_FACE: GLenum = 0x0B44;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_RED: GLenum = 0x1903;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;
pub const GL_R8: GLint = 0x8229;
pub const GL_RGBA8: GLint = 0x8058;
pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_FRAMEBUFFER: GLenum = 0x8D40;

pub const GetProcAddress = *const fn (name: [*:0]const u8) callconv(.c) ?*const anyopaque;

pub const Procs = struct {
    Enable: *const fn (GLenum) callconv(.c) void,
    Disable: *const fn (GLenum) callconv(.c) void,
    BlendFuncSeparate: *const fn (GLenum, GLenum, GLenum, GLenum) callconv(.c) void,
    Viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    Scissor: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    BindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    GenBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindBuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    BufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void,
    BufferSubData: *const fn (GLenum, GLintptr, GLsizeiptr, ?*const anyopaque) callconv(.c) void,
    GenVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindVertexArray: *const fn (GLuint) callconv(.c) void,
    EnableVertexAttribArray: *const fn (GLuint) callconv(.c) void,
    VertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void,
    CreateShader: *const fn (GLenum) callconv(.c) GLuint,
    DeleteShader: *const fn (GLuint) callconv(.c) void,
    ShaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const u8, ?[*]const GLint) callconv(.c) void,
    CompileShader: *const fn (GLuint) callconv(.c) void,
    GetShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) GLuint,
    DeleteProgram: *const fn (GLuint) callconv(.c) void,
    AttachShader: *const fn (GLuint, GLuint) callconv(.c) void,
    LinkProgram: *const fn (GLuint) callconv(.c) void,
    GetProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    UseProgram: *const fn (GLuint) callconv(.c) void,
    GetUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,
    Uniform1i: *const fn (GLint, GLint) callconv(.c) void,
    GenTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    ActiveTexture: *const fn (GLenum) callconv(.c) void,
    BindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    PixelStorei: *const fn (GLenum, GLint) callconv(.c) void,
    TexParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    TexImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    TexSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    DrawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void,

    pub fn load(get_proc: GetProcAddress) !Procs {
        var p: Procs = undefined;
        inline for (@typeInfo(Procs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "gl" ++ field_name;
            const sym = get_proc(name) orelse return error.MissingGlFunction;
            @field(p, field_name) = @ptrCast(sym);
        }
        return p;
    }
};

/// Framebuffer target for `OpenGlRenderer.record`.
pub const Target = struct {
    width: u32,
    height: u32,
    /// OpenGL framebuffer object ID (0 for the default window framebuffer).
    fbo: GLuint = 0,
};

pub const OpenGlRenderer = struct {
    gpa: std.mem.Allocator,
    gl: Procs,
    shape_prog: GLuint = 0,
    solid_prog: GLuint = 0,
    text_prog: GLuint = 0,
    image_prog: GLuint = 0,
    shape_vao: GLuint = 0,
    solid_vao: GLuint = 0,
    text_vao: GLuint = 0,
    vbo: GLuint = 0,
    vbo_capacity: usize = 0,
    cursor: usize = 0,
    atlas_tex: GLuint = 0,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    images: std.AutoHashMapUnmanaged(u64, GLuint) = .empty,
    rgba_scratch: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, get_proc: GetProcAddress) !OpenGlRenderer {
        const gl = try Procs.load(get_proc);
        return initWithProcs(gpa, gl);
    }

    pub fn initWithProcs(gpa: std.mem.Allocator, gl: Procs) !OpenGlRenderer {
        var r: OpenGlRenderer = .{ .gpa = gpa, .gl = gl };
        errdefer r.deinit();

        r.shape_prog = try r.compileProgram(shaders.glsl_shape_vs, shaders.glsl_shape_fs);
        r.solid_prog = try r.compileProgram(shaders.glsl_solid_vs, shaders.glsl_solid_fs);
        r.text_prog = try r.compileProgram(shaders.glsl_text_vs, shaders.glsl_text_fs);
        r.image_prog = try r.compileProgram(shaders.glsl_text_vs, shaders.glsl_image_fs);

        for ([_]GLuint{ r.text_prog, r.image_prog }) |prog| {
            r.gl.UseProgram(prog);
            const loc = r.gl.GetUniformLocation(prog, "u_tex");
            if (loc >= 0) r.gl.Uniform1i(loc, 0);
        }
        r.gl.UseProgram(0);

        var vaos: [3]GLuint = undefined;
        r.gl.GenVertexArrays(3, &vaos);
        r.shape_vao = vaos[0];
        r.solid_vao = vaos[1];
        r.text_vao = vaos[2];

        var vbo_id: [1]GLuint = undefined;
        r.gl.GenBuffers(1, &vbo_id);
        r.vbo = vbo_id[0];

        return r;
    }

    pub fn deinit(r: *OpenGlRenderer) void {
        var it = r.images.valueIterator();
        while (it.next()) |tex| {
            const t = [1]GLuint{tex.*};
            r.gl.DeleteTextures(1, &t);
        }
        r.images.deinit(r.gpa);
        r.rgba_scratch.deinit(r.gpa);
        if (r.atlas_tex != 0) {
            const t = [1]GLuint{r.atlas_tex};
            r.gl.DeleteTextures(1, &t);
        }
        if (r.vbo != 0) {
            const b = [1]GLuint{r.vbo};
            r.gl.DeleteBuffers(1, &b);
        }
        const vaos = [3]GLuint{ r.shape_vao, r.solid_vao, r.text_vao };
        if (r.shape_vao != 0) r.gl.DeleteVertexArrays(3, &vaos);
        for ([_]GLuint{ r.shape_prog, r.solid_prog, r.text_prog, r.image_prog }) |prog| {
            if (prog != 0) r.gl.DeleteProgram(prog);
        }
    }

    pub fn renderer(r: *OpenGlRenderer) renderer_mod.Renderer {
        return .of(r);
    }

    fn compileProgram(r: *const OpenGlRenderer, vs_src: [:0]const u8, fs_src: [:0]const u8) !GLuint {
        const vs = try r.compileShader(GL_VERTEX_SHADER, vs_src);
        defer r.gl.DeleteShader(vs);
        const fs = try r.compileShader(GL_FRAGMENT_SHADER, fs_src);
        defer r.gl.DeleteShader(fs);
        const prog = r.gl.CreateProgram();
        if (prog == 0) return error.GlCreateProgramFailed;
        errdefer r.gl.DeleteProgram(prog);
        r.gl.AttachShader(prog, vs);
        r.gl.AttachShader(prog, fs);
        r.gl.LinkProgram(prog);
        var ok: GLint = 0;
        r.gl.GetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.GlShaderLinkFailed;
        return prog;
    }

    fn compileShader(r: *const OpenGlRenderer, kind: GLenum, src: [:0]const u8) !GLuint {
        const sh = r.gl.CreateShader(kind);
        if (sh == 0) return error.GlCreateShaderFailed;
        errdefer r.gl.DeleteShader(sh);
        const ptrs = [1][*:0]const u8{src.ptr};
        r.gl.ShaderSource(sh, 1, &ptrs, null);
        r.gl.CompileShader(sh);
        var ok: GLint = 0;
        r.gl.GetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) return error.GlShaderCompileFailed;
        return sh;
    }

    pub fn prepare(r: *OpenGlRenderer, canvases: []const *const Canvas) !void {
        var bytes: usize = 0;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        r.cursor = 0;
        if (bytes > 0) {
            r.gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);
            if (bytes > r.vbo_capacity) {
                r.vbo_capacity = std.mem.alignForward(usize, bytes * 2, 64 * 1024);
                r.gl.BufferData(GL_ARRAY_BUFFER, @intCast(r.vbo_capacity), null, GL_STREAM_DRAW);
            } else {
                // Orphan the previous frame's buffer storage
                r.gl.BufferData(GL_ARRAY_BUFFER, @intCast(r.vbo_capacity), null, GL_STREAM_DRAW);
            }
        }
        for (canvases) |c| if (c.atlas) |a| r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *OpenGlRenderer, a: *atlas_mod.Atlas) void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        r.gl.ActiveTexture(GL_TEXTURE0);
        if (r.atlas_tex == 0) {
            var tex: [1]GLuint = undefined;
            r.gl.GenTextures(1, &tex);
            r.atlas_tex = tex[0];
            r.gl.BindTexture(GL_TEXTURE_2D, r.atlas_tex);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
            r.gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, null);
            r.atlas_stale = all;
        } else {
            r.gl.BindTexture(GL_TEXTURE_2D, r.atlas_tex);
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
        const y0: u32 = d.y0;
        const y1: u32 = @min(d.y1, h);
        if (y1 > y0) {
            r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
            r.gl.TexSubImage2D(
                GL_TEXTURE_2D,
                0,
                0,
                @intCast(y0),
                w,
                @intCast(y1 - y0),
                GL_RED,
                GL_UNSIGNED_BYTE,
                a.pixels[y0 * w .. y1 * w].ptr,
            );
        }
        r.atlas_stale = null;
    }

    fn uploadImages(r: *OpenGlRenderer, canvases: []const *const Canvas) !void {
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
            const tex = r.images.fetchRemove(id).?.value;
            const arr = [1]GLuint{tex};
            r.gl.DeleteTextures(1, &arr);
        }

        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            if (r.images.contains(img.id)) continue;
            const byte_count = @as(usize, img.width) * img.height * 4;
            try r.rgba_scratch.resize(r.gpa, byte_count);
            const out = r.rgba_scratch.items;
            for (img.pixels, 0..) |px, i| {
                out[i * 4 + 0] = @truncate(px >> 16);
                out[i * 4 + 1] = @truncate(px >> 8);
                out[i * 4 + 2] = @truncate(px);
                out[i * 4 + 3] = @truncate(px >> 24);
            }
            var tex: [1]GLuint = undefined;
            r.gl.GenTextures(1, &tex);
            r.gl.ActiveTexture(GL_TEXTURE0);
            r.gl.BindTexture(GL_TEXTURE_2D, tex[0]);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
            r.gl.TexImage2D(
                GL_TEXTURE_2D,
                0,
                GL_RGBA8,
                @intCast(img.width),
                @intCast(img.height),
                0,
                GL_RGBA,
                GL_UNSIGNED_BYTE,
                out.ptr,
            );
            try r.images.put(r.gpa, img.id, tex[0]);
        };
    }

    pub fn record(r: *OpenGlRenderer, c: *const Canvas, target: *const Target, damage: ?[]const Viewport) !void {
        if (target.width == 0 or target.height == 0) return;
        r.gl.BindFramebuffer(GL_FRAMEBUFFER, target.fbo);
        r.gl.Viewport(0, 0, @intCast(target.width), @intCast(target.height));
        r.gl.Disable(GL_DEPTH_TEST);
        r.gl.Disable(GL_CULL_FACE);
        r.gl.Enable(GL_SCISSOR_TEST);
        r.gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };

        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            const batch_vp = renderer_mod.scissor(area);
            if (!renderer_mod.covers(damage, batch_vp)) continue;
            if (r.cursor + data.len > r.vbo_capacity) return error.NotPrepared;

            r.gl.BufferSubData(GL_ARRAY_BUFFER, @intCast(r.cursor), @intCast(data.len), data.ptr);
            const byte_offset = r.cursor;
            r.cursor += std.mem.alignForward(usize, data.len, 16);

            switch (b.kind) {
                .@"opaque" => r.gl.Disable(GL_BLEND),
                else => {
                    r.gl.Enable(GL_BLEND);
                    r.gl.BlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                },
            }

            const prog: GLuint, const vao: GLuint, const layout: shaders.Layout = switch (b.kind) {
                .shape => .{ r.shape_prog, r.shape_vao, shaders.shape_layout },
                .solid, .@"opaque" => .{ r.solid_prog, r.solid_vao, shaders.solid_layout },
                .text => .{ r.text_prog, r.text_vao, shaders.text_layout },
                .image => .{ r.image_prog, r.text_vao, shaders.text_layout },
            };

            r.gl.UseProgram(prog);
            r.gl.BindVertexArray(vao);
            for (layout.attributes) |attr| {
                r.gl.EnableVertexAttribArray(attr.location);
                r.gl.VertexAttribPointer(
                    attr.location,
                    @intCast(attr.components),
                    GL_FLOAT,
                    GL_FALSE,
                    @intCast(layout.vertex_stride),
                    @ptrFromInt(byte_offset + attr.offset),
                );
            }

            switch (b.kind) {
                .text => {
                    r.gl.ActiveTexture(GL_TEXTURE0);
                    r.gl.BindTexture(GL_TEXTURE_2D, r.atlas_tex);
                },
                .image => {
                    const img = b.image orelse continue;
                    const tex = r.images.get(img.id) orelse return error.NotPrepared;
                    r.gl.ActiveTexture(GL_TEXTURE0);
                    r.gl.BindTexture(GL_TEXTURE_2D, tex);
                },
                else => {},
            }

            const clip_vp = if (b.clip) |clip| renderer_mod.scissor(clip) else full_vp;
            const count: GLsizei = @intCast(b.vertexCount());
            if (damage) |dmg_list| {
                for (dmg_list) |dmg| {
                    const sc = clip_vp.intersect(dmg) orelse continue;
                    r.setGlScissor(target.height, sc);
                    r.gl.DrawArrays(GL_TRIANGLES, 0, count);
                }
            } else {
                r.setGlScissor(target.height, clip_vp);
                r.gl.DrawArrays(GL_TRIANGLES, 0, count);
            }
        }
        r.gl.Disable(GL_SCISSOR_TEST);
    }

    fn setGlScissor(r: *const OpenGlRenderer, target_height: u32, vp: Viewport) void {
        const y_bottom = @as(i32, @intCast(target_height)) - (vp.y + @as(i32, @intCast(vp.height)));
        r.gl.Scissor(vp.x, y_bottom, @intCast(vp.width), @intCast(vp.height));
    }
};

test "OpenGlRenderer prepares batches, uploads atlas and images, and records draws" {
    const MockGl = struct {
        var next_id: GLuint = 1;
        var draws: usize = 0;
        var last_scissor: [4]GLint = .{ 0, 0, 0, 0 };

        fn enable(_: GLenum) callconv(.c) void {}
        fn disable(_: GLenum) callconv(.c) void {}
        fn blendFuncSeparate(_: GLenum, _: GLenum, _: GLenum, _: GLenum) callconv(.c) void {}
        fn viewport(_: GLint, _: GLint, _: GLsizei, _: GLsizei) callconv(.c) void {}
        fn scissor(x: GLint, y: GLint, w: GLsizei, h: GLsizei) callconv(.c) void {
            last_scissor = .{ x, y, w, h };
        }
        fn bindFramebuffer(_: GLenum, _: GLuint) callconv(.c) void {}
        fn genBuffers(n: GLsizei, out: [*]GLuint) callconv(.c) void {
            for (0..@intCast(n)) |i| {
                out[i] = next_id;
                next_id += 1;
            }
        }
        fn deleteBuffers(_: GLsizei, _: [*]const GLuint) callconv(.c) void {}
        fn bindBuffer(_: GLenum, _: GLuint) callconv(.c) void {}
        fn bufferData(_: GLenum, _: GLsizeiptr, _: ?*const anyopaque, _: GLenum) callconv(.c) void {}
        fn bufferSubData(_: GLenum, _: GLintptr, _: GLsizeiptr, _: ?*const anyopaque) callconv(.c) void {}
        fn genVertexArrays(n: GLsizei, out: [*]GLuint) callconv(.c) void {
            for (0..@intCast(n)) |i| {
                out[i] = next_id;
                next_id += 1;
            }
        }
        fn deleteVertexArrays(_: GLsizei, _: [*]const GLuint) callconv(.c) void {}
        fn bindVertexArray(_: GLuint) callconv(.c) void {}
        fn enableVertexAttribArray(_: GLuint) callconv(.c) void {}
        fn vertexAttribPointer(_: GLuint, _: GLint, _: GLenum, _: GLboolean, _: GLsizei, _: ?*const anyopaque) callconv(.c) void {}
        fn createShader(_: GLenum) callconv(.c) GLuint {
            defer next_id += 1;
            return next_id;
        }
        fn deleteShader(_: GLuint) callconv(.c) void {}
        fn shaderSource(_: GLuint, _: GLsizei, _: [*]const [*:0]const u8, _: ?[*]const GLint) callconv(.c) void {}
        fn compileShader(_: GLuint) callconv(.c) void {}
        fn getShaderiv(_: GLuint, _: GLenum, out: *GLint) callconv(.c) void {
            out.* = 1;
        }
        fn createProgram() callconv(.c) GLuint {
            defer next_id += 1;
            return next_id;
        }
        fn deleteProgram(_: GLuint) callconv(.c) void {}
        fn attachShader(_: GLuint, _: GLuint) callconv(.c) void {}
        fn linkProgram(_: GLuint) callconv(.c) void {}
        fn getProgramiv(_: GLuint, _: GLenum, out: *GLint) callconv(.c) void {
            out.* = 1;
        }
        fn useProgram(_: GLuint) callconv(.c) void {}
        fn getUniformLocation(_: GLuint, _: [*:0]const u8) callconv(.c) GLint {
            return 0;
        }
        fn uniform1i(_: GLint, _: GLint) callconv(.c) void {}
        fn genTextures(n: GLsizei, out: [*]GLuint) callconv(.c) void {
            for (0..@intCast(n)) |i| {
                out[i] = next_id;
                next_id += 1;
            }
        }
        fn deleteTextures(_: GLsizei, _: [*]const GLuint) callconv(.c) void {}
        fn activeTexture(_: GLenum) callconv(.c) void {}
        fn bindTexture(_: GLenum, _: GLuint) callconv(.c) void {}
        fn pixelStorei(_: GLenum, _: GLint) callconv(.c) void {}
        fn texParameteri(_: GLenum, _: GLenum, _: GLint) callconv(.c) void {}
        fn texImage2D(_: GLenum, _: GLint, _: GLint, _: GLsizei, _: GLsizei, _: GLint, _: GLenum, _: GLenum, _: ?*const anyopaque) callconv(.c) void {}
        fn texSubImage2D(_: GLenum, _: GLint, _: GLint, _: GLint, _: GLsizei, _: GLsizei, _: GLenum, _: GLenum, _: ?*const anyopaque) callconv(.c) void {}
        fn drawArrays(_: GLenum, _: GLint, _: GLsizei) callconv(.c) void {
            draws += 1;
        }
    };

    var gl_renderer = try OpenGlRenderer.initWithProcs(std.testing.allocator, .{
        .Enable = MockGl.enable,
        .Disable = MockGl.disable,
        .BlendFuncSeparate = MockGl.blendFuncSeparate,
        .Viewport = MockGl.viewport,
        .Scissor = MockGl.scissor,
        .BindFramebuffer = MockGl.bindFramebuffer,
        .GenBuffers = MockGl.genBuffers,
        .DeleteBuffers = MockGl.deleteBuffers,
        .BindBuffer = MockGl.bindBuffer,
        .BufferData = MockGl.bufferData,
        .BufferSubData = MockGl.bufferSubData,
        .GenVertexArrays = MockGl.genVertexArrays,
        .DeleteVertexArrays = MockGl.deleteVertexArrays,
        .BindVertexArray = MockGl.bindVertexArray,
        .EnableVertexAttribArray = MockGl.enableVertexAttribArray,
        .VertexAttribPointer = MockGl.vertexAttribPointer,
        .CreateShader = MockGl.createShader,
        .DeleteShader = MockGl.deleteShader,
        .ShaderSource = MockGl.shaderSource,
        .CompileShader = MockGl.compileShader,
        .GetShaderiv = MockGl.getShaderiv,
        .CreateProgram = MockGl.createProgram,
        .DeleteProgram = MockGl.deleteProgram,
        .AttachShader = MockGl.attachShader,
        .LinkProgram = MockGl.linkProgram,
        .GetProgramiv = MockGl.getProgramiv,
        .UseProgram = MockGl.useProgram,
        .GetUniformLocation = MockGl.getUniformLocation,
        .Uniform1i = MockGl.uniform1i,
        .GenTextures = MockGl.genTextures,
        .DeleteTextures = MockGl.deleteTextures,
        .ActiveTexture = MockGl.activeTexture,
        .BindTexture = MockGl.bindTexture,
        .PixelStorei = MockGl.pixelStorei,
        .TexParameteri = MockGl.texParameteri,
        .TexImage2D = MockGl.texImage2D,
        .TexSubImage2D = MockGl.texSubImage2D,
        .DrawArrays = MockGl.drawArrays,
    });
    defer gl_renderer.deinit();

    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(200, 100);
    c.setClip(.{ .x = 10, .y = 20, .w = 50, .h = 30 });
    c.fillRoundedRect(.{ .x = 10, .y = 20, .w = 50, .h = 30 }, .all(6), .rgb(0x6750a4));

    const target: Target = .{ .width = 200, .height = 100 };
    try gl_renderer.renderer().draw(&c, &target);
    try std.testing.expectEqual(@as(usize, 3), MockGl.draws);
    // OpenGL scissor flips Y: 100 - (20 + 30) = 50
    try std.testing.expectEqual([4]GLint{ 10, 50, 50, 30 }, MockGl.last_scissor);
}
