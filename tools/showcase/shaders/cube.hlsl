// The showcase's cube in HLSL (as cube.metal, cube.vert and cube.frag),
// compiled to DXBC by fxc when the showcase is built on Windows: coloured
// faces, lit from above left. Its attributes are read as TEXCOORD<location>,
// its uniforms are the constant buffer b0 (see gfx.D3D11Context).

struct Vertex {
    float3 pos : TEXCOORD0;
    float3 color : TEXCOORD1;
    float3 normal : TEXCOORD2;
};

cbuffer Uniforms : register(b0) {
    float4x4 mvp;
    float4x4 model;
};

struct Out {
    float4 position : SV_Position;
    float3 color : TEXCOORD0;
    float3 normal : TEXCOORD1;
};

Out vertex_main(Vertex v) {
    Out o;
    o.position = mul(mvp, float4(v.pos, 1.0));
    o.color = v.color;
    o.normal = mul(model, float4(v.normal, 0.0)).xyz;
    return o;
}

float4 pixel_main(Out i) : SV_Target {
    float shade = 0.35 + 0.65 * max(dot(normalize(i.normal), normalize(float3(-0.4, 0.6, 0.7))), 0.0);
    return float4(i.color * shade, 1.0);
}
