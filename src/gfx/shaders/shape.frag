#version 330 core
in vec4 v_local;
in vec2 v_shape;
in vec4 v_color;
out vec4 f_color;
void main() {
    vec2 p = abs(v_local.xy) - (v_local.zw - vec2(v_shape.x));
    float d = length(max(p, 0.0)) + min(max(p.x, p.y), 0.0) - v_shape.x;
    float outer = clamp(0.5 - d, 0.0, 1.0);
    float inner = v_shape.y > 0.0 ? clamp(0.5 - (d + v_shape.y), 0.0, 1.0) : 0.0;
    float cov = max(outer - inner, 0.0);
    f_color = vec4(v_color.rgb, v_color.a * cov);
}
