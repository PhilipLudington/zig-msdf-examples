#version 450

// Uniforms
layout(set = 0, binding = 0) uniform Uniforms {
    vec2 screen_size;
    float px_range;
    float _padding;
};

// Texture and sampler
layout(set = 1, binding = 0) uniform sampler2D msdf_texture;

// Inputs from vertex shader
layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

// Output color
layout(location = 0) out vec4 out_color;

// Compute median of three values - core of MSDF algorithm
float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

void main() {
    // Sample the MSDF texture
    vec3 msdf = texture(msdf_texture, frag_uv).rgb;

    // Compute the signed distance from the median of RGB channels
    float sd = median(msdf.r, msdf.g, msdf.b);

    // Calculate screen-space SDF pixel range for anti-aliasing
    // This adapts the sharpness based on how much the texture is scaled
    vec2 tex_size = vec2(textureSize(msdf_texture, 0));
    vec2 unit_range = vec2(px_range) / tex_size;
    vec2 screen_tex_size = vec2(1.0) / fwidth(frag_uv);
    float screen_px_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);

    // Calculate opacity with smooth anti-aliasing
    float screen_px_distance = screen_px_range * (sd - 0.5);
    float opacity = clamp(screen_px_distance + 0.5, 0.0, 1.0);

    // Output final color with computed alpha
    out_color = vec4(frag_color.rgb, frag_color.a * opacity);
}
