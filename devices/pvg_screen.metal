#include <metal_stdlib>
using namespace metal;
struct V { float4 at [[position]]; float2 uv; };
vertex V screen_v(uint i [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
  float2 c = float2(i & 1, (i >> 1) & 1);
  V o; o.at = float4(rect.xy + c * rect.zw, 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }
fragment float4 screen_plain(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
  return float4(t.sample(s, v.uv).rgb, 1); }
fragment float4 screen_linear(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint &mode [[buffer(0)]]) {
  float3 c = saturate(t.sample(s, v.uv).rgb);
  if (mode == 1) c = select(1.055 * powr(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
  return float4(c, 1); }
fragment float4 screen_cursor(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
  return t.sample(s, v.uv); }
