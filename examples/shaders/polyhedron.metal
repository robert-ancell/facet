// 3D polyhedron shader for `examples/metal.zig`, in the Metal Shading
// Language (as polyhedron.zig is for OpenGL and Vulkan): key and fill
// lighting with a specular highlight and rim, and a checkerboard.

#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
    float3 tint [[attribute(2)]];
    float3 normal [[attribute(3)]];
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    // Lighting (0 or 1), texturing (0 or 1).
    float4 options;
};

struct Out {
    float4 position [[position]];
    float2 uv;
    float3 tint;
    float3 normal;
    float3 world_pos;
};

constant float3 key_light = float3(-0.50, 0.65, 0.57);
constant float3 fill_light = float3(0.55, -0.60, 0.25);

vertex Out vertex_main(Vertex v [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    Out o;
    o.position = u.mvp * float4(v.pos, 1.0);
    o.uv = v.uv;
    o.tint = v.tint;
    o.normal = normalize((u.model * float4(v.normal, 0.0)).xyz);
    o.world_pos = (u.model * float4(v.pos, 1.0)).xyz;
    return o;
}

fragment float4 fragment_main(Out i [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(i.normal);
    float3 l_dir = normalize(key_light);
    float3 f_dir = normalize(fill_light);
    float3 v_dir = normalize(float3(0.0, 0.0, 3.3) - i.world_pos);
    float3 h_dir = normalize(l_dir + v_dir);

    // High-contrast key + subtle fill lighting with deep shadows (ambient 0.07)
    float key_diff = max(dot(n, l_dir), 0.0);
    float fill_diff = max(dot(n, f_dir), 0.0);
    float lit_diffuse = 0.07 + 1.08 * key_diff + 0.08 * fill_diff;

    // Crisp Blinn-Phong specular highlight (ndoth^32) + Fresnel rim
    float s32 = pow(max(dot(n, h_dir), 0.0), 32.0);
    float omv = 1.0 - max(dot(n, v_dir), 0.0);
    float rim = omv * omv * omv * 0.22 * key_diff;

    float lighting_on = u.options.x;
    float shade = 1.0 + (lit_diffuse - 1.0) * lighting_on;
    float spec = (s32 * 0.55 + rim) * lighting_on;

    // Checkerboard pattern
    float2 cell = floor(i.uv * 6.0);
    float cell_sum = cell.x + cell.y;
    float pat = cell_sum - 2.0 * floor(cell_sum * 0.5);
    float tex = 1.0 + (0.62 + 0.38 * pat - 1.0) * u.options.y;

    float3 rgb = clamp(i.tint * (shade * tex) + spec, 0.0, 1.0);
    return float4(rgb, 1.0);
}
