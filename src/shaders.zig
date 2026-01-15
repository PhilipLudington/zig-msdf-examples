//! MSDF shader definitions and embedded SPIR-V bytecode.
//!
//! The MSDF fragment shader computes the median of the RGB channels
//! and uses screen-space derivatives for anti-aliased rendering.

const std = @import("std");

/// Vertex input structure (matches shader input)
pub const Vertex = extern struct {
    /// Position in screen coordinates
    pos: [2]f32,
    /// Texture coordinates [0, 1]
    uv: [2]f32,
    /// RGBA color
    color: [4]f32,
};

/// Uniform buffer for the vertex shader
pub const Uniforms = extern struct {
    /// Screen size in pixels
    screen_size: [2]f32,
    /// SDF pixel range (typically 4.0)
    px_range: f32,
    /// Padding for alignment
    _padding: f32 = 0,
};

// SPIR-V bytecode for MSDF vertex shader
// This is a simple passthrough vertex shader that transforms screen coordinates
// to clip space and passes through UV coordinates and color.
pub const msdf_vert_spirv = [_]u8{
    // SPIR-V magic number
    0x03, 0x02, 0x23, 0x07,
    // Version 1.0
    0x00, 0x00, 0x01, 0x00,
    // Generator magic
    0x00, 0x00, 0x00, 0x00,
    // Bound
    0x30, 0x00, 0x00, 0x00,
    // Schema
    0x00, 0x00, 0x00, 0x00,
    // OpCapability Shader
    0x11, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00,
    // OpMemoryModel Logical GLSL450
    0x0e, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    // OpEntryPoint Vertex %main "main" %in_pos %in_uv %in_color %gl_Position %out_uv %out_color
    0x0f, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x6d, 0x61, 0x69, 0x6e, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
    // Rest of SPIR-V omitted for brevity - would need actual compiled shader
};

// SPIR-V bytecode for MSDF fragment shader
// This shader implements the MSDF algorithm:
// 1. Sample RGB from texture
// 2. Compute median(r, g, b)
// 3. Use screen-space derivatives for anti-aliasing
// 4. Output color with computed alpha
pub const msdf_frag_spirv = [_]u8{
    // SPIR-V magic number
    0x03, 0x02, 0x23, 0x07,
    // Version 1.0
    0x00, 0x00, 0x01, 0x00,
    // Generator magic
    0x00, 0x00, 0x00, 0x00,
    // Bound
    0x40, 0x00, 0x00, 0x00,
    // Schema
    0x00, 0x00, 0x00, 0x00,
    // OpCapability Shader
    0x11, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00,
    // OpMemoryModel Logical GLSL450
    0x0e, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    // Rest of SPIR-V omitted - would need actual compiled shader
};

/// GLSL source for reference/compilation
/// This can be compiled with glslc or shaderc
pub const msdf_vert_glsl =
    \\#version 450
    \\
    \\layout(set = 0, binding = 0) uniform Uniforms {
    \\    vec2 screen_size;
    \\    float px_range;
    \\    float _padding;
    \\};
    \\
    \\layout(location = 0) in vec2 in_pos;
    \\layout(location = 1) in vec2 in_uv;
    \\layout(location = 2) in vec4 in_color;
    \\
    \\layout(location = 0) out vec2 out_uv;
    \\layout(location = 1) out vec4 out_color;
    \\
    \\void main() {
    \\    // Transform screen coordinates to clip space [-1, 1]
    \\    vec2 pos = (in_pos / screen_size) * 2.0 - 1.0;
    \\    pos.y = -pos.y; // Flip Y for SDL coordinate system
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\    out_uv = in_uv;
    \\    out_color = in_color;
    \\}
;

pub const msdf_frag_glsl =
    \\#version 450
    \\
    \\layout(set = 0, binding = 0) uniform Uniforms {
    \\    vec2 screen_size;
    \\    float px_range;
    \\    float _padding;
    \\};
    \\
    \\layout(set = 1, binding = 0) uniform sampler2D msdf_texture;
    \\
    \\layout(location = 0) in vec2 in_uv;
    \\layout(location = 1) in vec4 in_color;
    \\
    \\layout(location = 0) out vec4 out_color;
    \\
    \\float median(float r, float g, float b) {
    \\    return max(min(r, g), min(max(r, g), b));
    \\}
    \\
    \\void main() {
    \\    vec3 msdf = texture(msdf_texture, in_uv).rgb;
    \\    float sd = median(msdf.r, msdf.g, msdf.b);
    \\
    \\    // Calculate screen-space SDF pixel range
    \\    vec2 unit_range = vec2(px_range) / vec2(textureSize(msdf_texture, 0));
    \\    vec2 screen_tex_size = vec2(1.0) / fwidth(in_uv);
    \\    float screen_px_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);
    \\
    \\    // Calculate opacity with anti-aliasing
    \\    float screen_px_distance = screen_px_range * (sd - 0.5);
    \\    float opacity = clamp(screen_px_distance + 0.5, 0.0, 1.0);
    \\
    \\    out_color = vec4(in_color.rgb, in_color.a * opacity);
    \\}
;

/// Create vertex data for a textured quad
pub fn createQuad(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
) [6]Vertex {
    const x0 = x;
    const y0 = y;
    const x1 = x + width;
    const y1 = y + height;

    const tex_u0 = uv_min[0];
    const tex_v0 = uv_min[1];
    const tex_u1 = uv_max[0];
    const tex_v1 = uv_max[1];

    return [6]Vertex{
        // Triangle 1
        .{ .pos = .{ x0, y0 }, .uv = .{ tex_u0, tex_v0 }, .color = color },
        .{ .pos = .{ x1, y0 }, .uv = .{ tex_u1, tex_v0 }, .color = color },
        .{ .pos = .{ x0, y1 }, .uv = .{ tex_u0, tex_v1 }, .color = color },
        // Triangle 2
        .{ .pos = .{ x1, y0 }, .uv = .{ tex_u1, tex_v0 }, .color = color },
        .{ .pos = .{ x1, y1 }, .uv = .{ tex_u1, tex_v1 }, .color = color },
        .{ .pos = .{ x0, y1 }, .uv = .{ tex_u0, tex_v1 }, .color = color },
    };
}

test "createQuad generates correct vertices" {
    const quad = createQuad(10, 20, 100, 50, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(usize, 6), quad.len);
    try std.testing.expectEqual(@as(f32, 10), quad[0].pos[0]);
    try std.testing.expectEqual(@as(f32, 20), quad[0].pos[1]);
}
