#version 330 core
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_tex;
out vec4 f_color;
void main() {
    float cov = texture(u_tex, v_uv).r;
    f_color = vec4(v_color.rgb, v_color.a * cov);
}
