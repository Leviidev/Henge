#include <metal_stdlib>
using namespace metal;
extern "C" uint inventory_transform(uint value);
kernel void dynamic_consumer(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) { out[i]=inventory_transform(i); }
