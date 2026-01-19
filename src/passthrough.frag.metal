#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct Uniforms
{
    float2 screen_size;
    float px_range;
    float _padding;
};

struct main0_out
{
    float4 out_color [[color(0)]];
};

struct main0_in
{
    float2 frag_uv [[user(locn0)]];
    float4 frag_color [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant Uniforms& _67 [[buffer(0)]], texture2d<float> msdf_texture [[texture(0)]], sampler msdf_textureSmplr [[sampler(0)]])
{
    main0_out out = {};
    // Just output the raw texture color multiplied by vertex color
    float4 tex_color = msdf_texture.sample(msdf_textureSmplr, in.frag_uv);
    out.out_color = tex_color * in.frag_color;
    return out;
}
