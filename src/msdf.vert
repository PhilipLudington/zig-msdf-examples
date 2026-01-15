#version 450

// Uniforms
layout(set = 0, binding = 0) uniform Uniforms {
    vec2 screen_size;
    float px_range;
    float _padding;
};

// Vertex inputs
layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

// Outputs to fragment shader
layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

void main() {
    // Transform screen coordinates to clip space [-1, 1]
    vec2 pos = (in_pos / screen_size) * 2.0 - 1.0;
    pos.y = -pos.y; // Flip Y for SDL coordinate system

    gl_Position = vec4(pos, 0.0, 1.0);
    frag_uv = in_uv;
    frag_color = in_color;
}
