#include <metal_stdlib>
using namespace metal;
vertex float4 journal_v(uint i [[vertex_id]]) { return float4(float(i & 1u),float((i >> 1u)&1u),0,1); }
fragment float4 journal_f() { return float4(1,0,0,1); }
