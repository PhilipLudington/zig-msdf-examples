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

static inline __attribute__((always_inline))
float median(thread const float& r, thread const float& g, thread const float& b)
{
    return fast::max(fast::min(r, g), fast::min(fast::max(r, g), b));
}

fragment main0_out main0(main0_in in [[stage_in]], constant Uniforms& _67 [[buffer(0)]], texture2d<float> msdf_texture [[texture(0)]], sampler msdf_textureSmplr [[sampler(0)]])
{
    main0_out out = {};
    float3 msdf = msdf_texture.sample(msdf_textureSmplr, in.frag_uv).xyz;
    float param = msdf.x;
    float param_1 = msdf.y;
    float param_2 = msdf.z;
    float sd = median(param, param_1, param_2);
    float2 tex_size = float2(int2(msdf_texture.get_width(), msdf_texture.get_height()));
    float2 unit_range = float2(_67.px_range) / tex_size;
    float2 screen_tex_size = float2(1.0) / fwidth(in.frag_uv);
    float screen_px_range = fast::max(0.5 * dot(unit_range, screen_tex_size), 1.0);
    float screen_px_distance = screen_px_range * (sd - 0.5);
    float opacity = fast::clamp(screen_px_distance + 0.5, 0.0, 1.0);
    out.out_color = float4(in.frag_color.xyz, in.frag_color.w * opacity);
    return out;
}

