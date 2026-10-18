#version 330 core

in vec2 v_uv;
in vec3 v_tint;
in vec3 v_normal;
in vec3 v_world_pos;

layout(std140) uniform Uniforms {
    mat4 u_mvp;
    mat4 u_model;
    vec4 u_options;
};

out vec4 f_color;

void main() {
    vec3 n = normalize(v_normal);
    vec3 l_dir = normalize(vec3(-0.50, 0.65, 0.57));
    vec3 f_dir = normalize(vec3(0.55, -0.60, 0.25));
    vec3 v_dir = normalize(vec3(0.0, 0.0, 3.3) - v_world_pos);
    vec3 h_dir = normalize(l_dir + v_dir);

    float key_diff = max(dot(n, l_dir), 0.0);
    float fill_diff = max(dot(n, f_dir), 0.0);
    float lit_diffuse = 0.07 + 1.08 * key_diff + 0.08 * fill_diff;

    float ndoth = max(dot(n, h_dir), 0.0);
    float s32 = pow(ndoth, 32.0);

    float omv = 1.0 - max(dot(n, v_dir), 0.0);
    float rim = omv * omv * omv * 0.22 * key_diff;

    float lighting_on = u_options.x;
    float shade = mix(1.0, lit_diffuse, lighting_on);
    float spec = (s32 * 0.55 + rim) * lighting_on;

    vec2 cell = floor(v_uv * 6.0);
    float pat = mod(cell.x + cell.y, 2.0);
    float tex = mix(1.0, 0.62 + 0.38 * pat, u_options.y);

    vec3 rgb = clamp(v_tint * (shade * tex) + vec3(spec), 0.0, 1.0);
    f_color = vec4(rgb, 1.0);
}
