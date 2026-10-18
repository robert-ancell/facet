#version 330 core

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_color;
layout(location = 2) in vec3 a_normal;

layout(std140) uniform Uniforms {
    mat4 u_mvp;
    mat4 u_model;
};

out vec3 v_color;
out vec3 v_normal;

void main() {
    gl_Position = u_mvp * vec4(a_pos, 1.0);
    v_color = a_color;
    v_normal = mat3(u_model) * a_normal;
}
