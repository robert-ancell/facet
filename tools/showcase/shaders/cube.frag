#version 330 core

in vec3 v_color;
in vec3 v_normal;

out vec4 f_color;

void main() {
    float shade = 0.35 + 0.65 * max(dot(normalize(v_normal), normalize(vec3(-0.4, 0.6, 0.7))), 0.0);
    f_color = vec4(v_color * shade, 1.0);
}
