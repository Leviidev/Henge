#include <metal_stdlib>
using namespace metal;
constant bool mode [[function_constant(0)]];
kernel void beta(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) { out[i]=2000u+(mode?100u:0u)+i; }
