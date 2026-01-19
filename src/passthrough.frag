#version 450

// Uniforms (same structure for pipeline compatibility)
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

void main() {
    // Just output the raw texture color multiplied by vertex color
    vec4 tex_color = texture(msdf_texture, frag_uv);
    out_color = tex_color * frag_color;
}
