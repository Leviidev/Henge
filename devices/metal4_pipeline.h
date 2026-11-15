#pragma once
#import <Metal/Metal.h>
#import <objc/runtime.h>

static inline void hv_metal4_note_function(id<MTLFunction> function,id<MTLLibrary> library) {
    if (@available(macOS 26.0,iOS 26.0,*)) {
        /* This is called immediately after UNSPECIALIZED newFunctionWithName.
           A declaration of optional/default constants is not evidence that
           unknown specialization values were supplied. Recreate this exact
           library entry; the Metal4 compiler applies its declared defaults.
           Values-specialized functions must retain their own descriptor. */
        if(!function || !library || ![library.device supportsFamily:MTLGPUFamilyMetal4])return;
        MTL4LibraryFunctionDescriptor *d=[MTL4LibraryFunctionDescriptor new];
        d.library=library;d.name=function.name;
        objc_setAssociatedObject(function,"henge.metal4.function",d,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static inline id hv_metal4_descriptor_reject(NSString **reason,NSString *message) {
    if(reason)*reason=message;return nil;
}
static inline id hv_metal4_descriptor_checked(uint32_t tag,id descriptor,NSString **reason) API_AVAILABLE(macos(26.0),ios(26.0));
static inline id hv_metal4_descriptor_checked(uint32_t tag,id descriptor,NSString **reason) {
    if(tag==0xb){
        MTLComputePipelineDescriptor *old=descriptor;
        MTL4FunctionDescriptor *f=objc_getAssociatedObject(old.computeFunction,"henge.metal4.function");
        if(!f)return hv_metal4_descriptor_reject(reason,@"compute library/function descriptor unavailable");
        if(old.linkedFunctions.functions.count || old.linkedFunctions.binaryFunctions.count)return hv_metal4_descriptor_reject(reason,@"linked compute functions need compatibility");
        /* Metal4 has no compute stage-input layout/region interface. Never
           drop a real legacy vertex-fetch layout when converting a pipeline. */
        MTLStageInputOutputDescriptor *input=old.stageInputDescriptor;
        if(input)for(NSUInteger i=0;i<31;i++)
            if(input.attributes[i].format!=MTLAttributeFormatInvalid)return hv_metal4_descriptor_reject(reason,@"legacy compute stage-input layout needs compatibility");
        MTL4ComputePipelineDescriptor *d=[MTL4ComputePipelineDescriptor new];
        d.label=old.label;d.computeFunctionDescriptor=f;
        d.threadGroupSizeIsMultipleOfThreadExecutionWidth=old.threadGroupSizeIsMultipleOfThreadExecutionWidth;
        d.maxTotalThreadsPerThreadgroup=old.maxTotalThreadsPerThreadgroup;
        d.supportIndirectCommandBuffers=old.supportIndirectCommandBuffers?MTL4IndirectCommandBufferSupportStateEnabled:MTL4IndirectCommandBufferSupportStateDisabled;
        return d;
    }
    if(tag!=0xe)return hv_metal4_descriptor_reject(reason,@"tile/unknown pipeline needs compatibility");
    MTLRenderPipelineDescriptor *old=descriptor;
    MTL4FunctionDescriptor *v=objc_getAssociatedObject(old.vertexFunction,"henge.metal4.function");
    MTL4FunctionDescriptor *f=objc_getAssociatedObject(old.fragmentFunction,"henge.metal4.function");
    if(!v || (old.fragmentFunction && !f))return hv_metal4_descriptor_reject(reason,@"render library/function descriptor unavailable");
    if(old.vertexFunction.patchType!=MTLPatchTypeNone)return hv_metal4_descriptor_reject(reason,@"tessellation pipeline needs compatibility");
    if(old.vertexLinkedFunctions.functions.count || old.fragmentLinkedFunctions.functions.count ||
       old.vertexLinkedFunctions.binaryFunctions.count || old.fragmentLinkedFunctions.binaryFunctions.count)return hv_metal4_descriptor_reject(reason,@"linked render functions need compatibility");
    MTL4RenderPipelineDescriptor *d=[MTL4RenderPipelineDescriptor new];
    d.label=old.label;d.vertexFunctionDescriptor=v;d.fragmentFunctionDescriptor=f;
    d.vertexDescriptor=old.vertexDescriptor;d.rasterSampleCount=old.rasterSampleCount;
    d.rasterizationEnabled=old.rasterizationEnabled;d.inputPrimitiveTopology=old.inputPrimitiveTopology;
    d.maxVertexAmplificationCount=old.maxVertexAmplificationCount;
    d.alphaToCoverageState=old.alphaToCoverageEnabled?MTL4AlphaToCoverageStateEnabled:MTL4AlphaToCoverageStateDisabled;
    d.alphaToOneState=old.alphaToOneEnabled?MTL4AlphaToOneStateEnabled:MTL4AlphaToOneStateDisabled;
    d.supportIndirectCommandBuffers=old.supportIndirectCommandBuffers?MTL4IndirectCommandBufferSupportStateEnabled:MTL4IndirectCommandBufferSupportStateDisabled;
    for(NSUInteger i=0;i<8;i++){
        MTLRenderPipelineColorAttachmentDescriptor *a=old.colorAttachments[i];
        MTL4RenderPipelineColorAttachmentDescriptor *b=d.colorAttachments[i];
        b.pixelFormat=a.pixelFormat;b.writeMask=a.writeMask;
        b.blendingState=a.blendingEnabled?MTL4BlendStateEnabled:MTL4BlendStateDisabled;
        b.rgbBlendOperation=a.rgbBlendOperation;b.alphaBlendOperation=a.alphaBlendOperation;
        b.sourceRGBBlendFactor=a.sourceRGBBlendFactor;b.destinationRGBBlendFactor=a.destinationRGBBlendFactor;
        b.sourceAlphaBlendFactor=a.sourceAlphaBlendFactor;b.destinationAlphaBlendFactor=a.destinationAlphaBlendFactor;
    }
    return d;
}
static inline id hv_metal4_descriptor(uint32_t tag,id descriptor) API_AVAILABLE(macos(26.0),ios(26.0));
static inline id hv_metal4_descriptor(uint32_t tag,id descriptor) {
    return hv_metal4_descriptor_checked(tag,descriptor,NULL);
}
