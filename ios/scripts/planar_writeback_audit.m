/* Bounded shared planar IOSurface coherency oracle. No shaders are dispatched.
 * Usage: planar-writeback-audit REPORT.json [--skip-gpu-write|--texture-views]
 * Full active-byte comparisons; row padding is deliberately not an image pixel.
 * --skip-gpu-write is a negative control, never a compatibility fallback. */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <CommonCrypto/CommonDigest.h>
#include <unistd.h>

static NSString *ReportPath;
static BOOL TimedOut;
static BOOL UseTextureViews;
static void Save(NSDictionary *report) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if(ReportPath)[json writeToFile:ReportPath options:NSDataWritingAtomic error:nil];
}
static NSString *Hash(const void *bytes,NSUInteger length) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,(CC_LONG)length,hash);
    NSMutableString *s=[NSMutableString new];for(unsigned i=0;i<sizeof(hash);i++)[s appendFormat:@"%02x",hash[i]];return s;
}
static NSUInteger Bad(const uint8_t *actual,const uint8_t *expected,NSUInteger length) {
    NSUInteger bad=0;for(NSUInteger i=0;i<length;i++)bad+=actual[i]!=expected[i];return bad;
}
static NSDictionary *Finish(id<MTLCommandBuffer> cb) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed){dispatch_semaphore_signal(done);}];[cb commit];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))){TimedOut=YES;return @{@"completed":@NO,@"timeout_seconds":@15};}
    return @{@"completed":@(cb.status==MTLCommandBufferStatusCompleted),@"status":@(cb.status),@"error":cb.error.description?:@""};
}
static NSDictionary *Snapshot(CVPixelBufferRef pixel,NSArray *textures,NSArray *outputs,NSArray *expected,NSArray *bytesPerElement,id<MTLCommandQueue> queue) {
    id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    for(NSUInteger p=0;p<2;p++) {
        id<MTLTexture> t=textures[p];id<MTLBuffer> out=outputs[p];NSUInteger row=(t.width*[bytesPerElement[p] unsignedIntegerValue]+255)&~255ul;
        memset(out.contents,0xC7,out.length);
        [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(t.width,t.height,1)
                    toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*t.height];
    }[blit endEncoding];NSDictionary *completion=Finish(cb);
    if(TimedOut)return @{@"passed":@NO,@"command":completion};
    NSMutableArray *planes=[NSMutableArray new];BOOL passed=[completion[@"completed"] boolValue];
    CVReturn lock=CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    passed&=lock==kCVReturnSuccess;
    for(NSUInteger p=0;p<2;p++) {
        id<MTLTexture> t=textures[p];id<MTLBuffer> out=outputs[p];NSData *ref=expected[p];NSUInteger active=t.width*[bytesPerElement[p] unsignedIntegerValue],row=(active+255)&~255ul;
        NSMutableData *gpu=[NSMutableData dataWithLength:active*t.height],*cpu=[NSMutableData dataWithLength:active*t.height];
        uint8_t *cpuBase=lock==kCVReturnSuccess?CVPixelBufferGetBaseAddressOfPlane(pixel,p):NULL;NSUInteger stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,p);
        for(NSUInteger y=0;y<t.height;y++) {
            memcpy((uint8_t *)gpu.mutableBytes+y*active,(uint8_t *)out.contents+y*row,active);
            if(cpuBase)memcpy((uint8_t *)cpu.mutableBytes+y*active,cpuBase+y*stride,active);
        }
        NSUInteger gb=Bad(gpu.bytes,ref.bytes,ref.length),cbad=cpuBase?Bad(cpu.bytes,ref.bytes,ref.length):ref.length;
        passed&=gb==0&&cbad==0;
        [planes addObject:@{@"plane":@(p),@"active_bytes":@(ref.length),@"gpu_mismatched_bytes":@(gb),@"cpu_mismatched_bytes":@(cbad),
            @"expected_sha256":Hash(ref.bytes,ref.length),@"gpu_sha256":Hash(gpu.bytes,gpu.length),@"cpu_sha256":Hash(cpu.bytes,cpu.length)}];
    }
    CVReturn unlock=lock==kCVReturnSuccess?CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly):lock;passed&=unlock==kCVReturnSuccess;
    return @{@"passed":@(passed),@"command":completion,@"cpu_lock":@(lock),@"cpu_unlock":@(unlock),@"planes":planes};
}
static NSDictionary *GPUWrite(NSArray *textures,NSArray *inputs,NSArray *expected,NSArray *bpes,id<MTLCommandQueue> queue,BOOL partial,BOOL skip) {
    id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    NSMutableArray *regions=[NSMutableArray new];
    for(NSUInteger p=0;p<(partial?1:2);p++) {
        id<MTLTexture> t=textures[p];id<MTLBuffer> in=inputs[p];NSMutableData *ref=expected[p];NSUInteger bpe=[bpes[p] unsignedIntegerValue],active=t.width*bpe,row=(active+255)&~255ul;
        id<MTLTexture> target=UseTextureViews?[t newTextureViewWithPixelFormat:t.pixelFormat]:t;
        if(!target){[blit endEncoding];return @{@"command":@{@"completed":@NO,@"error":@"texture_view_creation_failed"}};}
        NSUInteger x=partial?16:0,y=partial?8:0,w=partial?32:t.width,h=partial?16:t.height;
        memset(in.contents,0x8B,in.length);
        for(NSUInteger yy=0;yy<h;yy++)for(NSUInteger xx=0;xx<w*bpe;xx++) {
            uint8_t value=(uint8_t)((xx+yy*active)*37+yy*17+p*53+(partial?0xD3:0x37));
            ((uint8_t *)in.contents)[yy*row+xx]=value;
            ((uint8_t *)ref.mutableBytes)[(yy+y)*active+x*bpe+xx]=value;
        }
        if(!skip)[blit copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row*h sourceSize:MTLSizeMake(w,h,1)
                           toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x,y,0)];
        [regions addObject:@{@"plane":@(p),@"x":@(x),@"y":@(y),@"width":@(w),@"height":@(h)}];
    }
    [blit endEncoding];return @{@"command":Finish(cb),@"regions":regions,@"write_deliberately_skipped":@(skip)};
}
int main(int argc,char **argv){@autoreleasepool {
    if(argc<2||argc>3){fprintf(stderr,"usage: planar-writeback-audit REPORT.json [--skip-gpu-write|--texture-views]\n");return 64;}
    BOOL skip=argc==3&&!strcmp(argv[2],"--skip-gpu-write");UseTextureViews=argc==3&&!strcmp(argv[2],"--texture-views");if(argc==3&&!skip&&!UseTextureViews)return 64;
    ReportPath=@(argv[1]);alarm(90);NSApplicationLoad();id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device)device=MTLCopyAllDevices().firstObject;
    NSMutableDictionary *report=[@{@"schema":@1,@"probe":@"planar-writeback-01",@"device":device.name?:@"none",@"os":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"negative_control":@(skip),@"texture_view_writes":@(UseTextureViews),@"status":@"running",@"cases":[NSMutableArray new],@"synchronization":@"shared textures; completed Metal commands before CVPixelBuffer CPU lock; no managed-storage synchronization",@"shader_dispatch":@NO} mutableCopy];Save(report);
    if(!device){report[@"status"]=@"no_metal_device";Save(report);return 2;}
    id<MTLCommandQueue> queue=[device newCommandQueue];BOOL all=YES;
    for(NSNumber *format in @[@(0x34323066u),@(0x34323076u),@(0x78663230u),@(0x78343230u)])for(NSNumber *width in @[@256,@258]) {@autoreleasepool {
        NSUInteger w=width.unsignedIntegerValue,h=w==256?128:130;BOOL ten=format.unsignedIntValue==0x78663230u||format.unsignedIntValue==0x78343230u;
        NSMutableDictionary *entry=[@{@"fourcc":format,@"width":@(w),@"height":@(h),@"stages":[NSMutableArray new]} mutableCopy];[report[@"cases"] addObject:entry];
        CVPixelBufferRef pixel=NULL;CVReturn created=CVPixelBufferCreate(kCFAllocatorDefault,w,h,format.unsignedIntValue,
          (__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{},(__bridge id)kCVPixelBufferMetalCompatibilityKey:@YES},&pixel);
        entry[@"create"]=@(created);if(created||!pixel){all=NO;Save(report);continue;}
        IOSurfaceRef surface=CVPixelBufferGetIOSurface(pixel);NSUInteger planes=IOSurfaceGetPlaneCount(surface);entry[@"planes"]=@(planes);
        if(planes!=2){all=NO;CVPixelBufferRelease(pixel);Save(report);continue;}
        NSMutableArray *textures=[NSMutableArray new],*inputs=[NSMutableArray new],*outputs=[NSMutableArray new],*refs=[NSMutableArray new],*bpes=[NSMutableArray new],*layouts=[NSMutableArray new];
        BOOL valid=YES;
        for(NSUInteger p=0;p<2;p++) {
            NSUInteger pw=IOSurfaceGetWidthOfPlane(surface,p),ph=IOSurfaceGetHeightOfPlane(surface,p),bpe=(ten?2:1)*(p?2:1),active=pw*bpe,row=(active+255)&~255ul;
            MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ten?(p?MTLPixelFormatRG16Unorm:MTLPixelFormatR16Unorm):(p?MTLPixelFormatRG8Unorm:MTLPixelFormatR8Unorm) width:pw height:ph mipmapped:NO];
            td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsagePixelFormatView;
            id<MTLTexture> tex=[device newTextureWithDescriptor:td iosurface:surface plane:p];id<MTLBuffer> in=[device newBufferWithLength:row*ph options:MTLResourceStorageModeShared],out=[device newBufferWithLength:row*ph options:MTLResourceStorageModeShared];
            if(!tex||!in||!out){valid=NO;break;}[textures addObject:tex];[inputs addObject:in];[outputs addObject:out];[bpes addObject:@(bpe)];[refs addObject:[NSMutableData dataWithLength:active*ph]];
            [layouts addObject:@{@"plane":@(p),@"width":@(pw),@"height":@(ph),@"active_row_bytes":@(active),@"surface_stride":@(IOSurfaceGetBytesPerRowOfPlane(surface,p)),@"staging_stride":@(row)}];
        }
        entry[@"textures_created"]=@(valid);entry[@"layouts"]=layouts;if(!valid){all=NO;CVPixelBufferRelease(pixel);Save(report);continue;}
        CVReturn lock=CVPixelBufferLockBaseAddress(pixel,0);entry[@"seed_lock"]=@(lock);
        if(lock!=kCVReturnSuccess){all=NO;CVPixelBufferRelease(pixel);Save(report);continue;}
        for(NSUInteger p=0;p<2;p++) {
            id<MTLTexture> tex=textures[p];NSUInteger stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,p),active=tex.width*[bpes[p] unsignedIntegerValue];uint8_t *dst=CVPixelBufferGetBaseAddressOfPlane(pixel,p);NSMutableData *ref=refs[p];
            memset(dst,0xEE,stride*tex.height);memset(ref.mutableBytes,p?0x80:0x50,ref.length);
            for(NSUInteger y=0;y<tex.height;y++)memcpy(dst+y*stride,(uint8_t *)ref.bytes+y*active,active);
        }
        CVReturn unlocked=CVPixelBufferUnlockBaseAddress(pixel,0);entry[@"seed_unlock"]=@(unlocked);BOOL caseOK=unlocked==kCVReturnSuccess;
        for(NSUInteger stage=0;stage<4&&!TimedOut;stage++) {
            NSMutableDictionary *step=[@{@"stage":@[@"cpu_seed",@"gpu_full_write",@"cpu_sparse_after_gpu",@"gpu_partial_after_cpu"][stage]} mutableCopy];[entry[@"stages"] addObject:step];Save(report);
            fprintf(stderr,"fourcc=%08x size=%lux%lu stage=%lu\n",format.unsignedIntValue,(unsigned long)w,(unsigned long)h,(unsigned long)stage);fflush(stderr);
            if(stage==1||stage==3){NSDictionary *write=GPUWrite(textures,inputs,refs,bpes,queue,stage==3,skip);step[@"gpu_write"]=write;caseOK&=[write[@"command"][@"completed"] boolValue];}
            if(stage==2) {
                CVReturn editLock=CVPixelBufferLockBaseAddress(pixel,0);step[@"edit_lock"]=@(editLock);caseOK&=editLock==kCVReturnSuccess;
                NSMutableArray *edits=[NSMutableArray new];
                if(editLock==kCVReturnSuccess)for(NSUInteger p=0;p<2;p++) {
                    id<MTLTexture> tex=textures[p];NSMutableData *ref=refs[p];NSUInteger active=tex.width*[bpes[p] unsignedIntegerValue],stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,p),xbyte=13,y=3;
                    uint8_t *ptr=CVPixelBufferGetBaseAddressOfPlane(pixel,p);uint8_t newValue=((uint8_t *)ref.mutableBytes)[y*active+xbyte]^0x5A;
                    /* Assign only this byte; deriving from actual CPU data could conceal stale readback. */
                    ptr[y*stride+xbyte]=newValue;((uint8_t *)ref.mutableBytes)[y*active+xbyte]=newValue;
                    [edits addObject:@{@"plane":@(p),@"byte_in_row":@(xbyte),@"y":@(y),@"value":@(newValue)}];
                }
                CVReturn editUnlock=editLock==kCVReturnSuccess?CVPixelBufferUnlockBaseAddress(pixel,0):editLock;step[@"edit_unlock"]=@(editUnlock);step[@"edits"]=edits;caseOK&=editUnlock==kCVReturnSuccess;
            }
            if(TimedOut){step[@"passed"]=@NO;caseOK=NO;Save(report);break;}
            NSDictionary *snapshot=Snapshot(pixel,textures,outputs,refs,bpes,queue);step[@"snapshot"]=snapshot;step[@"passed"]=@([snapshot[@"passed"] boolValue]&&caseOK);caseOK&=[snapshot[@"passed"] boolValue];Save(report);
        }
        entry[@"passed"]=@(caseOK&&!TimedOut);all&=caseOK&&!TimedOut;CVPixelBufferRelease(pixel);Save(report);
        if(TimedOut)goto finish;
    }}
finish:
    report[@"status"]=TimedOut?@"gpu_timeout":@"complete";report[@"passed"]=@(all&&!TimedOut);report[@"scope"]=@"8 finite format/size cases, 4 stages; all active bytes in both planes checked through GPU and CPU. No video color conversion, shader execution, concurrency, or arbitrary-format proof.";Save(report);alarm(0);
    puts([[NSString stringWithFormat:@"status=%@ passed=%@ report=%@",report[@"status"],report[@"passed"],ReportPath] UTF8String]);return all&&!TimedOut?0:1;
}}
