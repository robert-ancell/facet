// The canvas's shaders in HLSL, for the Direct3D 11 renderer (compiled to
// DXBC by fxc when kete is built on Windows): the same as the Metal and
// GLSL ones (see shaders.zig), their vertices read with input layouts of
// `shape_layout`, `solid_layout` and `text_layout`.

struct ShapeIn {
    float2 pos : POSITION;
    float4 local : TEXCOORD0;
    float2 shape : TEXCOORD1;
    float4 color : COLOR;
};

struct ShapeOut {
    float4 position : SV_Position;
    float4 local : TEXCOORD0;
    float2 shape : TEXCOORD1;
    float4 color : COLOR;
};

ShapeOut shape_vs(ShapeIn i) {
    ShapeOut o;
    o.position = float4(i.pos, 0.0, 1.0);
    o.local = i.local;
    o.shape = i.shape;
    o.color = i.color;
    return o;
}

float4 shape_ps(ShapeOut i) : SV_Target {
    float2 p = abs(i.local.xy) - (i.local.zw - float2(i.shape.x, i.shape.x));
    float d = length(max(p, 0.0)) + min(max(p.x, p.y), 0.0) - i.shape.x;
    float outer = saturate(0.5 - d);
    float inner = i.shape.y > 0.0 ? saturate(0.5 - (d + i.shape.y)) : 0.0;
    float cov = max(outer - inner, 0.0);
    return float4(i.color.rgb, i.color.a * cov);
}

struct SolidIn {
    float2 pos : POSITION;
    float4 color : COLOR;
};

struct SolidOut {
    float4 position : SV_Position;
    float4 color : COLOR;
};

SolidOut solid_vs(SolidIn i) {
    SolidOut o;
    o.position = float4(i.pos, 0.0, 1.0);
    o.color = i.color;
    return o;
}

float4 solid_ps(SolidOut i) : SV_Target {
    return i.color;
}

struct TextIn {
    float2 pos : POSITION;
    float2 uv : TEXCOORD0;
    float4 color : COLOR;
};

struct TextOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR;
};

TextOut text_vs(TextIn i) {
    TextOut o;
    o.position = float4(i.pos, 0.0, 1.0);
    o.uv = i.uv;
    o.color = i.color;
    return o;
}

Texture2D tex : register(t0);
SamplerState smp : register(s0);

// Glyphs: their coverage, from the single-channel atlas.
float4 text_ps(TextOut i) : SV_Target {
    float cov = tex.Sample(smp, i.uv).r;
    return float4(i.color.rgb, i.color.a * cov);
}

// Images, tinted.
float4 image_ps(TextOut i) : SV_Target {
    return tex.Sample(smp, i.uv) * i.color;
}
