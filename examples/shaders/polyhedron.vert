#version 330 core

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_tint;
layout(location = 3) in vec3 a_normal;

layout(std140) uniform Uniforms {
    mat4 u_mvp;
    mat4 u_model;
    vec4 u_options;
};

out vec2 v_uv;
out vec3 v_tint;
out vec3 v_normal;
out vec3 v_world_pos;

void main() {
    gl_Position = u_mvp * vec4(a_pos, 1.0);
    v_uv = a_uv;
    v_tint = a_tint;
    v_normal = normalize(mat3(u_model) * a_normal);
    v_world_pos = (u_model * vec4(a_pos, 1.0)).xyz;
}
