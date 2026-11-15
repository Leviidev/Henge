#include <metal_stdlib>
using namespace metal;
#if defined(HENGE_ARCHIVE_FUNC_av)
struct ArchiveVertex { float4 position [[position]]; };
vertex ArchiveVertex av(uint i [[vertex_id]]) { (void)i; return {float4(0,0,0,1)}; }
#elif defined(HENGE_ARCHIVE_FUNC_af)
fragment float4 af() { return float4(1,0,0,1); }
#elif defined(HENGE_ARCHIVE_FUNC_anr)
vertex void anr(uint i [[vertex_id]]) { (void)i; }
#elif defined(HENGE_ARCHIVE_FUNC_ak)
kernel void ak(device uint *v [[buffer(0)]]) { v[0]=7; }
#elif defined(HENGE_ARCHIVE_FUNC_ak2)
kernel void ak2(device uint *v [[buffer(0)]]) { v[0]=8; }
#else
// Independent API control: several entrypoints in one library, unlike guest
// function records, which each contain one exact single-function metallib.
struct ArchiveVertex { float4 position [[position]]; };
vertex ArchiveVertex av(uint i [[vertex_id]]) { (void)i; return {float4(0,0,0,1)}; }
fragment float4 af() { return float4(1,0,0,1); }
vertex void anr(uint i [[vertex_id]]) { (void)i; }
kernel void ak(device uint *v [[buffer(0)]]) { v[0]=7; }
kernel void ak2(device uint *v [[buffer(0)]]) { v[0]=8; }
#endif
