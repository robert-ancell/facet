// The canvas's shaders in the Metal Shading Language, for the Metal
// renderer (compiled when it starts): the same as the GLSL ones (see
// shaders.zig), the vertices read from the batch's buffer by their index,
// with the layouts `shape_layout`, `solid_layout` and `text_layout`.

#include <metal_stdlib>
using namespace metal;

struct ShapeVertex {
    packed_float2 pos;
    packed_float4 local;
    packed_float2 shape;
    packed_float4 color;
};

struct ShapeOut {
    float4 position [[position]];
    float4 local;
    float2 shape;
    float4 color;
};

vertex ShapeOut shape_vs(uint vid [[vertex_id]], const device ShapeVertex *v [[buffer(0)]]) {
    ShapeVertex i = v[vid];
    ShapeOut o;
    o.position = float4(float2(i.pos), 0.0, 1.0);
    o.local = float4(i.local);
    o.shape = float2(i.shape);
    o.color = float4(i.color);
    return o;
}

fragment float4 shape_fs(ShapeOut i [[stage_in]]) {
    float2 p = abs(i.local.xy) - (i.local.zw - float2(i.shape.x));
    float d = length(max(p, 0.0)) + min(max(p.x, p.y), 0.0) - i.shape.x;
    float outer = clamp(0.5 - d, 0.0, 1.0);
    float inner = i.shape.y > 0.0 ? clamp(0.5 - (d + i.shape.y), 0.0, 1.0) : 0.0;
    float cov = max(outer - inner, 0.0);
    return float4(i.color.rgb, i.color.a * cov);
}

struct SolidVertex {
    packed_float2 pos;
    packed_float4 color;
};

struct SolidOut {
    float4 position [[position]];
    float4 color;
};

vertex SolidOut solid_vs(uint vid [[vertex_id]], const device SolidVertex *v [[buffer(0)]]) {
    SolidVertex i = v[vid];
    SolidOut o;
    o.position = float4(float2(i.pos), 0.0, 1.0);
    o.color = float4(i.color);
    return o;
}

fragment float4 solid_fs(SolidOut i [[stage_in]]) {
    return i.color;
}

struct TextVertex {
    packed_float2 pos;
    packed_float2 uv;
    packed_float4 color;
};

struct TextOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex TextOut text_vs(uint vid [[vertex_id]], const device TextVertex *v [[buffer(0)]]) {
    TextVertex i = v[vid];
    TextOut o;
    o.position = float4(float2(i.pos), 0.0, 1.0);
    o.uv = float2(i.uv);
    o.color = float4(i.color);
    return o;
}

// Glyphs: their coverage, from the single-channel atlas.
fragment float4 text_fs(TextOut i [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float cov = tex.sample(s, i.uv).r;
    return float4(i.color.rgb, i.color.a * cov);
}

// Images, tinted.
fragment float4 image_fs(TextOut i [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    return tex.sample(s, i.uv) * i.color;
}
