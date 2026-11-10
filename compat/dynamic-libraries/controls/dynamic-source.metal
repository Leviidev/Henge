#include <metal_stdlib>
using namespace metal;
extern "C" uint inventory_transform(uint value) { return value*7u+19u; }
