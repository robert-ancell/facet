// The showcase's cube in the Metal Shading Language (as cube.vert and
// cube.frag): coloured faces, lit from above left.

#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 pos [[attribute(0)]];
    float3 color [[attribute(1)]];
    float3 normal [[attribute(2)]];
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
};

struct Out {
    float4 position [[position]];
    float3 color;
    float3 normal;
};

vertex Out vertex_main(Vertex v [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    Out o;
    o.position = u.mvp * float4(v.pos, 1.0);
    o.color = v.color;
    o.normal = (u.model * float4(v.normal, 0.0)).xyz;
    return o;
}

fragment float4 fragment_main(Out i [[stage_in]]) {
    float shade = 0.35 + 0.65 * max(dot(normalize(i.normal), normalize(float3(-0.4, 0.6, 0.7))), 0.0);
    return float4(i.color * shade, 1.0);
}
