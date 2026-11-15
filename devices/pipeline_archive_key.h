/* Stable lookup hints only. Metal's FailOnBinaryArchiveMiss still validates the
   full pipeline; an omitted opaque property can cause a miss, never a wrong PSO. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
static inline NSData *hv_archive_digest(NSData *bytes) {
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);
    const unsigned char *p=bytes.bytes;NSUInteger n=bytes.length;
    while(n){CC_LONG take=(CC_LONG)MIN(n,(NSUInteger)(1u<<20));CC_SHA256_Update(&ctx,p,take);p+=take;n-=take;}
    CC_SHA256_Final(out,&ctx);return [NSData dataWithBytes:out length:sizeof out];
}
static inline void hv_archive_associate_function(id<MTLFunction> f,NSData *bytes) {
    if(f && !objc_getAssociatedObject(f,"henge.function.digest"))
        objc_setAssociatedObject(f,"henge.function.digest",hv_archive_digest(bytes),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline void hv_archive_number(NSMutableData *key,uint64_t number){[key appendBytes:&number length:sizeof number];}
static inline void hv_archive_function(NSMutableData *key,id<MTLFunction> f){
    NSData *binary=objc_getAssociatedObject(f,"henge.function.digest");
    NSData *name=[(f.name ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    hv_archive_number(key,binary.length);if(binary)[key appendData:binary];
    hv_archive_number(key,name.length);[key appendData:name];hv_archive_number(key,f.functionType);
}
static inline NSString *hv_pipeline_archive_hint(uint32_t tag,id descriptor){
    NSMutableData *key=[NSMutableData new];hv_archive_number(key,tag);
    if(tag==0xe){
        MTLRenderPipelineDescriptor *r=descriptor;hv_archive_function(key,r.vertexFunction);hv_archive_function(key,r.fragmentFunction);
        hv_archive_number(key,r.rasterSampleCount);hv_archive_number(key,r.rasterizationEnabled);
        hv_archive_number(key,r.alphaToCoverageEnabled);hv_archive_number(key,r.alphaToOneEnabled);
        hv_archive_number(key,r.depthAttachmentPixelFormat);hv_archive_number(key,r.stencilAttachmentPixelFormat);
        for(unsigned i=0;i<8;i++){
            MTLRenderPipelineColorAttachmentDescriptor *c=r.colorAttachments[i];
            hv_archive_number(key,c.pixelFormat);hv_archive_number(key,c.writeMask);hv_archive_number(key,c.blendingEnabled);
            hv_archive_number(key,c.rgbBlendOperation);hv_archive_number(key,c.alphaBlendOperation);
            hv_archive_number(key,c.sourceRGBBlendFactor);hv_archive_number(key,c.destinationRGBBlendFactor);
            hv_archive_number(key,c.sourceAlphaBlendFactor);hv_archive_number(key,c.destinationAlphaBlendFactor);
        }
        for(unsigned i=0;i<31;i++){
            MTLVertexAttributeDescriptor *a=r.vertexDescriptor.attributes[i];MTLVertexBufferLayoutDescriptor *b=r.vertexDescriptor.layouts[i];
            hv_archive_number(key,a.format);hv_archive_number(key,a.offset);hv_archive_number(key,a.bufferIndex);
            hv_archive_number(key,b.stride);hv_archive_number(key,b.stepFunction);hv_archive_number(key,b.stepRate);
        }
    }else if(tag==0xb){
        MTLComputePipelineDescriptor *c=descriptor;hv_archive_function(key,c.computeFunction);
        hv_archive_number(key,c.threadGroupSizeIsMultipleOfThreadExecutionWidth);hv_archive_number(key,c.maxTotalThreadsPerThreadgroup);
    }else hv_archive_function(key,[(MTLTileRenderPipelineDescriptor *)descriptor tileFunction]);
    NSData *digest=hv_archive_digest(key);const unsigned char *p=digest.bytes;char hex[65];
    for(unsigned i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",p[i]);
    return [NSString stringWithFormat:@"%u-%s",tag,hex];
}
