//! Shared Platonic solid geometry (meshes with non-adjacent face coloring) and
//! 4×4 column-major matrix math for `examples/opengl.zig` and
//! `examples/vulkan.zig`.

const std = @import("std");

pub const Shape = enum {
    tetrahedron,
    cube,
    octahedron,
    dodecahedron,
    icosahedron,

    pub fn triangles(s: Shape) u32 {
        return switch (s) {
            .tetrahedron => 4,
            .cube => 12,
            .octahedron => 8,
            .dodecahedron => 36,
            .icosahedron => 20,
        };
    }

    pub fn name(s: Shape) []const u8 {
        return switch (s) {
            .tetrahedron => "Tetrahedron",
            .cube => "Cube",
            .octahedron => "Octahedron",
            .dodecahedron => "Dodecahedron",
            .icosahedron => "Icosahedron",
        };
    }
};

pub const shapes = std.enums.values(Shape);

pub const Look = struct {
    lighting: bool = true,
    texturing: bool = true,
};

pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    tint: [3]f32,
    normal: [3]f32,
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u16,

    pub fn deinit(m: Mesh, gpa: std.mem.Allocator) void {
        gpa.free(m.vertices);
        gpa.free(m.indices);
    }
};

const phi: f32 = (1.0 + @sqrt(5.0)) / 2.0;
const solid_radius: f32 = @sqrt(3.0);

const face_tints = [_][3]f32{
    .{ 0.95, 0.32, 0.38 },
    .{ 0.25, 0.82, 0.52 },
    .{ 0.32, 0.58, 0.98 },
    .{ 0.96, 0.78, 0.24 },
    .{ 0.82, 0.42, 0.96 },
    .{ 0.24, 0.84, 0.88 },
};

const V3 = @Vector(3, f32);

fn dot3(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}

fn cross3(a: V3, b: V3) V3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize3(a: V3) V3 {
    return a / @as(V3, @splat(@sqrt(dot3(a, a))));
}

fn corners(shape: Shape) []const [3]f32 {
    const ip = 1.0 / phi;
    return switch (shape) {
        .tetrahedron => &.{ .{ 1, 1, 1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ -1, -1, 1 } },
        .cube => &.{
            .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 },
            .{ -1, -1, 1 },  .{ 1, -1, 1 },  .{ -1, 1, 1 },  .{ 1, 1, 1 },
        },
        .octahedron => &.{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } },
        .dodecahedron => &.{
            .{ -1, -1, -1 }, .{ 1, -1, -1 },   .{ -1, 1, -1 },   .{ 1, 1, -1 },
            .{ -1, -1, 1 },  .{ 1, -1, 1 },    .{ -1, 1, 1 },    .{ 1, 1, 1 },
            .{ 0, ip, phi }, .{ 0, -ip, phi }, .{ 0, ip, -phi }, .{ 0, -ip, -phi },
            .{ ip, phi, 0 }, .{ -ip, phi, 0 }, .{ ip, -phi, 0 }, .{ -ip, -phi, 0 },
            .{ phi, 0, ip }, .{ -phi, 0, ip }, .{ phi, 0, -ip }, .{ -phi, 0, -ip },
        },
        .icosahedron => &.{
            .{ 0, 1, phi }, .{ 0, -1, phi }, .{ 0, 1, -phi }, .{ 0, -1, -phi },
            .{ 1, phi, 0 }, .{ -1, phi, 0 }, .{ 1, -phi, 0 }, .{ -1, -phi, 0 },
            .{ phi, 0, 1 }, .{ -phi, 0, 1 }, .{ phi, 0, -1 }, .{ -phi, 0, -1 },
        },
    };
}

/// Builds the indexed triangle mesh for `shape`, coloring faces so no two
/// adjacent faces (sharing an edge) have the same color.
pub fn buildMesh(gpa: std.mem.Allocator, shape: Shape) !Mesh {
    const raw = corners(shape);
    var pts: [20]V3 = undefined;
    for (raw, pts[0..raw.len]) |c, *p| p.* = normalize3(c) * @as(V3, @splat(solid_radius));
    const ps = pts[0..raw.len];
    const eps = 1e-3;

    const Face = struct {
        corners: [8]usize = undefined,
        len: usize = 0,
        normal: V3,
        center: V3,
        u_axis: V3,
        v_axis: V3,
        max_u: f32,
    };

    var faces: std.ArrayList(Face) = .empty;
    defer faces.deinit(gpa);

    for (0..ps.len) |i| for (i + 1..ps.len) |j| for (j + 1..ps.len) |k| {
        const c = cross3(ps[j] - ps[i], ps[k] - ps[i]);
        if (dot3(c, c) < eps) continue;
        var n = normalize3(c);
        var d = dot3(n, ps[i]);
        if (d < 0) {
            n = -n;
            d = -d;
        }
        const outer = for (ps) |p| {
            if (dot3(n, p) > d + eps) break false;
        } else true;
        if (!outer) continue;
        const known = for (faces.items) |f| {
            if (dot3(n, f.normal) > 1 - eps) break true;
        } else false;
        if (known) continue;

        var face: [8]usize = undefined;
        var fn_len: usize = 0;
        var center: V3 = @splat(0);
        for (ps, 0..) |p, pi| if (@abs(dot3(n, p) - d) <= eps) {
            face[fn_len] = pi;
            fn_len += 1;
            center += p;
        };
        center /= @splat(@floatFromInt(fn_len));
        const u_axis = normalize3(ps[face[0]] - center);
        const v_axis = cross3(n, u_axis);
        var angles: [8]f32 = undefined;
        for (face[0..fn_len], angles[0..fn_len]) |pi, *a| {
            const rel = ps[pi] - center;
            a.* = std.math.atan2(dot3(rel, v_axis), dot3(rel, u_axis));
        }
        for (0..fn_len) |a| for (a + 1..fn_len) |b| if (angles[b] < angles[a]) {
            std.mem.swap(f32, &angles[a], &angles[b]);
            std.mem.swap(usize, &face[a], &face[b]);
        };

        var max_u: f32 = 0;
        for (face[0..fn_len]) |pi| {
            const rel = ps[pi] - center;
            max_u = @max(max_u, @max(@abs(dot3(rel, u_axis)), @abs(dot3(rel, v_axis))));
        }

        try faces.append(gpa, .{
            .corners = face,
            .len = fn_len,
            .normal = n,
            .center = center,
            .u_axis = u_axis,
            .v_axis = v_axis,
            .max_u = max_u,
        });
    };

    var face_colors = try gpa.alloc(usize, faces.items.len);
    defer gpa.free(face_colors);
    @memset(face_colors, std.math.maxInt(usize));

    for (faces.items, 0..) |f, fi| {
        var best_color: usize = 0;
        var best_max_dot: f32 = std.math.inf(f32);

        for (0..face_tints.len) |cand| {
            var neighbor_conflict = false;
            var max_same_dot: f32 = -2.0;

            for (faces.items[0..fi], 0..) |other, oi| {
                if (face_colors[oi] != cand) continue;
                var shared_corners: usize = 0;
                for (f.corners[0..f.len]) |ca| {
                    for (other.corners[0..other.len]) |cb| {
                        if (ca == cb) shared_corners += 1;
                    }
                }
                if (shared_corners >= 2) {
                    neighbor_conflict = true;
                    break;
                }
                max_same_dot = @max(max_same_dot, dot3(f.normal, other.normal));
            }

            if (!neighbor_conflict and max_same_dot < best_max_dot) {
                best_max_dot = max_same_dot;
                best_color = cand;
            }
        }
        face_colors[fi] = best_color;
    }

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(gpa);
    var indices: std.ArrayList(u16) = .empty;
    errdefer indices.deinit(gpa);

    for (faces.items, face_colors) |f, color_idx| {
        const tint = face_tints[color_idx];
        const base: u16 = @intCast(vertices.items.len);
        for (f.corners[0..f.len]) |pi| {
            const rel = ps[pi] - f.center;
            try vertices.append(gpa, .{
                .pos = ps[pi],
                .uv = .{
                    (dot3(rel, f.u_axis) / f.max_u + 1.0) * 0.5,
                    (dot3(rel, f.v_axis) / f.max_u + 1.0) * 0.5,
                },
                .tint = tint,
                .normal = f.normal,
            });
        }
        for (1..f.len - 1) |t_i| {
            try indices.appendSlice(gpa, &.{ base, base + @as(u16, @intCast(t_i)), base + @as(u16, @intCast(t_i + 1)) });
        }
    }

    return .{
        .vertices = try vertices.toOwnedSlice(gpa),
        .indices = try indices.toOwnedSlice(gpa),
    };
}

// --- 4×4 Column-Major Matrix Helpers -----------------------------------------

pub const Mat4 = [16]f32;

pub fn matIdentity() Mat4 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

pub fn matMul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = @splat(0);
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| {
                sum += a[k * 4 + row] * b[col * 4 + k];
            }
            out[col * 4 + row] = sum;
        }
    }
    return out;
}

pub fn matTranslate(tx: f32, ty: f32, tz: f32) Mat4 {
    var m = matIdentity();
    m[12] = tx;
    m[13] = ty;
    m[14] = tz;
    return m;
}

pub fn matRotX(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{
        1, 0,  0, 0,
        0, c,  s, 0,
        0, -s, c, 0,
        0, 0,  0, 1,
    };
}

pub fn matRotY(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{
        c, 0, -s, 0,
        0, 1, 0,  0,
        s, 0, c,  0,
        0, 0, 0,  1,
    };
}

pub fn matRotZ(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{
        c,  s, 0, 0,
        -s, c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1,
    };
}

/// Perspective matrix mapping depth `[near, far]` to `[0, 1]` (compatible with
/// both Vulkan `[0, 1]` and OpenGL `[-1, 1]` clip spaces).
pub fn matPerspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy * 0.5);
    const nf = 1.0 / (near - far);
    return .{
        f / aspect, 0, 0,             0,
        0,          f, 0,             0,
        0,          0, far * nf,      -1,
        0,          0, far * near * nf, 0,
    };
}

pub fn modelMatrix(yaw: f32, pitch: f32, roll: f32) Mat4 {
    return matMul(matRotY(yaw), matMul(matRotX(pitch), matRotZ(roll)));
}

pub fn mvpMatrix(aspect: f32, model: Mat4) Mat4 {
    const view = matTranslate(0, 0, -4.6);
    const proj = matPerspective(std.math.degreesToRadians(42.0), aspect, 1.0, 12.0);
    return matMul(proj, matMul(view, model));
}
