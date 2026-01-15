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
    float2 frag_uv [[user(locn0)]];
    float4 frag_color [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float2 in_pos [[attribute(0)]];
    float2 in_uv [[attribute(1)]];
    float4 in_color [[attribute(2)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant Uniforms& _15 [[buffer(0)]])
{
    main0_out out = {};
    float2 pos = ((in.in_pos / _15.screen_size) * 2.0) - float2(1.0);
    pos.y = -pos.y;
    out.gl_Position = float4(pos, 0.0, 1.0);
    out.frag_uv = in.in_uv;
    out.frag_color = in.in_color;
    return out;
}

