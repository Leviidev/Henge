#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "pvg_lite.h"
#include "display_snapshot.h"
#include <string.h>
#include "vmapple.h"
#include <stdlib.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <assert.h>
#include "pipeline_archive_key.h"

/* Exercise real Metal command completion while the guest board is destroyed.
   Empty execs avoid simulator limitations on guest buffer-backed textures. */
static HvMachine machine;
static HvCpu cpus[2];
static HvVmapple board;

/* Declare only the production cache interface here; its implementation is linked
   through pvg_metal.o. These fixture libraries never enter a Metal encoder. */
@protocol CachePressureTesting
@property(nonatomic, readonly) NSUInteger count;
- (void)setAdmissionBytes:(NSUInteger)bytes entries:(NSUInteger)entries;
- (id<MTLLibrary>)libraryForData:(NSData *)data loader:(id<MTLLibrary>(^)(void))loader;
@end
@protocol PlanarTesting
- (void)preparePlanar:(id)surface descriptor:(const uint8_t *)desc compact:(BOOL)compact identity:(NSData *)identity;
@end
static void planarGuestPages(HvPvgMetal *metal) {
    id replay=(__bridge id)metal;dispatch_queue_t worker=[replay valueForKey:@"worker"];
    dispatch_sync(worker, ^{
        id<MTLDevice> device=[replay valueForKey:@"device"];
        uint8_t desc[1024]={0};uint32_t fourcc='b3a8';memcpy(desc+4,&fourcc,4);desc[0x3e]=2;
        uint64_t four=4,alloc=16384;memcpy(desc+0x18,&alloc,8);memcpy(desc+0x20,&four,8);memcpy(desc+0x28,&four,8);
        for(unsigned i=0;i<2;i++){
            uint8_t *plane=desc+0x80+i*0x80;uint64_t offset=i*1024,size=1024,row=256;uint16_t bpe=i?1:4;
            memcpy(plane+8,&offset,8);memcpy(plane+0x18,&size,8);memcpy(plane+0x20,&four,8);memcpy(plane+0x28,&four,8);memcpy(plane+0x30,&row,8);memcpy(plane+0x38,&bpe,2);
        }
        NSData *identity=[@"fixture-b3a8-pages" dataUsingEncoding:NSUTF8StringEncoding];
        id<MTLBuffer> pages=[device newBufferWithLength:alloc options:MTLResourceStorageModeShared];assert(pages);
        id surface=[NSClassFromString(@"HvObject")new];[surface setValue:pages forKey:@"object"];[surface setValue:@YES forKey:@"mapping_in_buffer"];[surface setValue:@(alloc) forKey:@"alloc"];[surface setValue:@(fourcc) forKey:@"fourcc"];
        Ivar mapped=class_getInstanceVariable([surface class],"mapped");*(void **)((uint8_t *)(__bridge void *)surface+ivar_getOffset(mapped))=pages.contents;
        [(id<PlanarTesting>)replay preparePlanar:surface descriptor:desc compact:NO identity:identity];
        id entry=[surface valueForKey:@"planar_entry"];assert(entry);
        BOOL direct=[[entry valueForKey:@"shared_pages"]boolValue];
        if(direct){
            id second=[NSClassFromString(@"HvObject")new];[second setValue:pages forKey:@"object"];[second setValue:@YES forKey:@"mapping_in_buffer"];[second setValue:@(alloc) forKey:@"alloc"];[second setValue:@(fourcc) forKey:@"fourcc"];
            *(void **)((uint8_t *)(__bridge void *)second+ivar_getOffset(mapped))=pages.contents;
            [(id<PlanarTesting>)replay preparePlanar:second descriptor:desc compact:NO identity:identity];
            assert([second valueForKey:@"planar_entry"]==entry && [second valueForKey:@"object"]==pages);
            MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:4 height:4 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            id<MTLTexture> alpha=[pages newTextureWithDescriptor:td offset:1024 bytesPerRow:256];assert(alpha);
            id<MTLCommandQueue> queue=[replay valueForKey:@"queue"];id<MTLCommandBuffer> cb=[queue commandBuffer];
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=alpha;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
            id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:pass];assert(encoder);[encoder endEncoding];[cb commit];[cb waitUntilCompleted];assert(!cb.error);
            for(unsigned y=0;y<4;y++)assert(((uint8_t *)pages.contents)[1024+y*256]==255);
        }
        printf("planar guest pages: Safari b3a8 direct=%d; immutable allocation backend and mapping identity retained%s\n",direct,direct?"; GPU alpha writes visible in guest bytes":"; runtime XR probe selected reference IOSurface");
    });
}

@protocol ArchiveTesting
- (id)pipelineState:(uint32_t)tag descriptor:(id)descriptor error:(NSError **)error;
- (void)saveArchive;
@end
static void archiveCoverage(HvPvgMetal *metal,int cycle) {
    setenv("HV_PVG_ARCHIVE_DEBUG","1",1);
    id replay=(__bridge id)metal;
    dispatch_queue_t worker=[replay valueForKey:@"worker"];
    dispatch_sync(worker, ^{
        id<MTLDevice> device=[replay valueForKey:@"device"];
        /* Production archives refer to exact guest metallib bytes. A source
           recompilation may change library identifiers; do not mistake that
           for a failed cross-process binary-cache lookup. */
#ifndef HENGE_TEST_ARCHIVE_FIXTURE
#define HENGE_TEST_ARCHIVE_FIXTURE "build/archive_fixture.metallib"
#endif
        NSError *error=nil;
        NSString *directory=[@HENGE_TEST_ARCHIVE_FIXTURE stringByDeletingLastPathComponent];
        id<MTLFunction>(^function)(NSString *)=^id<MTLFunction>(NSString *name){
            NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"archive_%@.metallib",name]];
            NSData *bytes=[NSData dataWithContentsOfFile:path];assert(bytes.length);
            dispatch_data_t data=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *load_error=nil;id<MTLLibrary> single=[device newLibraryWithData:data error:&load_error];
            assert(single && single.functionNames.count==1 && !load_error);
            id<MTLFunction> f=[single newFunctionWithName:name];assert(f);hv_archive_associate_function(f,bytes);return f;
        };
        MTLRenderPipelineDescriptor *render=[MTLRenderPipelineDescriptor new];
        render.vertexFunction=function(@"av");render.fragmentFunction=function(@"af");
        render.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
        id<ArchiveTesting> cache=(id)replay;
        id initial=[cache pipelineState:0xe descriptor:render error:&error];
        if(!initial || error)fprintf(stderr,"archive render cycle=%d state=%d error=%s\n",cycle,initial!=nil,error.localizedDescription.UTF8String ?: "none");
        assert(initial && !error);
        if(cycle || getenv("HENGE_TEST_ARCHIVE_REOPEN"))assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>0);
        assert([cache pipelineState:0xe descriptor:render error:&error] && !error);
        assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>0);
        void(^execute_compute)(id,uint32_t)=^(id pipeline,uint32_t expected){
            id<MTLBuffer> output=[device newBufferWithLength:4 options:MTLResourceStorageModeShared];assert(output);*(uint32_t *)output.contents=0;
            id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
            [e setComputePipelineState:pipeline];[e setBuffer:output offset:0 atIndex:0];[e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];assert(!cb.error && *(uint32_t *)output.contents==expected);
        };
        MTLComputePipelineDescriptor *compute=[MTLComputePipelineDescriptor new];compute.computeFunction=function(@"ak");
        uint64_t before_compute=[[replay valueForKey:@"pipes_hit"]unsignedLongLongValue];
        id compute_state=[cache pipelineState:0xb descriptor:compute error:&error];assert(compute_state && !error);
        if(cycle || getenv("HENGE_TEST_ARCHIVE_REOPEN"))assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>before_compute);
        execute_compute(compute_state,7);
        uint64_t before_warm=[[replay valueForKey:@"pipes_hit"]unsignedLongLongValue];
        assert([cache pipelineState:0xb descriptor:compute error:&error] && !error);
        assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>before_warm);
        // Distinct descriptors and kernels must all survive a later replay
        // and fresh-process reopening, including delayed archive saving.
        MTLRenderPipelineDescriptor *other_render=[render copy];other_render.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
        uint64_t before_other=[[replay valueForKey:@"pipes_hit"]unsignedLongLongValue];
        id other=[cache pipelineState:0xe descriptor:other_render error:&error];assert(other && !error);
        if(cycle || getenv("HENGE_TEST_ARCHIVE_REOPEN"))assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>before_other);
        MTLComputePipelineDescriptor *other_compute=[MTLComputePipelineDescriptor new];other_compute.computeFunction=function(@"ak2");
        before_other=[[replay valueForKey:@"pipes_hit"]unsignedLongLongValue];
        other=[cache pipelineState:0xb descriptor:other_compute error:&error];assert(other && !error);
        if(cycle || getenv("HENGE_TEST_ARCHIVE_REOPEN"))assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>before_other);
        execute_compute(other,8);
        before_warm=[[replay valueForKey:@"pipes_hit"]unsignedLongLongValue];
        assert([cache pipelineState:0xb descriptor:other_compute error:&error] && !error);
        assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>before_warm);
        [cache saveArchive];assert(![replay valueForKey:@"archive_save_timer"]);
        [replay setValue:@1 forKey:@"memory_pressure"];
        [replay performSelector:@selector(refreshCacheBudget)];
        assert(![[replay valueForKey:@"archive_pressure_suspended"]boolValue]);
        assert([replay valueForKey:@"archive_paths"] && ![[replay valueForKey:@"archive_handles"]count]);
        uint64_t warning_hits=[[replay valueForKey:@"pipes_hit"]unsignedLongLongValue];
        id warning_state=[cache pipelineState:0xb descriptor:other_compute error:&error];assert(warning_state && !error);
        execute_compute(warning_state,8);
        assert([[replay valueForKey:@"pipes_hit"]unsignedLongLongValue]>warning_hits);
        [replay setValue:@0 forKey:@"memory_pressure"];
        [replay performSelector:@selector(refreshCacheBudget)];
        render.fragmentFunction=nil;render.vertexFunction=function(@"anr");render.rasterizationEnabled=NO;
        id fragmentless=[cache pipelineState:0xe descriptor:render error:&error];
        if(!fragmentless || error)fprintf(stderr,"fragmentless pipeline: %s\n",error.localizedDescription.UTF8String ?: "no state");
        assert(fragmentless && !error && !render.binaryArchives.count);
        assert([[replay valueForKey:@"pipes_unsaveable"]unsignedLongLongValue]>0);
    });
}

static void taskRetirement(HvPvgMetal *metal) {
    id replay=(__bridge id)metal;
    dispatch_queue_t worker=[replay valueForKey:@"worker"];
    NSMutableDictionary *tasks=[replay valueForKey:@"tasks"];
    dispatch_sync(worker, ^{
        tasks[@1]=[NSMutableDictionary new]; tasks[@2]=[NSMutableDictionary new];
    });
    uint32_t *command=calloc(4,sizeof *command);assert(command);
    command[0]=0x20;command[1]=16;command[3]=2;
    hv_pvg_metal_submit(metal,board.pvg,0,command,16);
    dispatch_sync(worker, ^{ assert(tasks[@1] && !tasks[@2]); [tasks removeAllObjects]; });
}

static void cachePressure(HvPvgMetal *metal) {
    id replay=(__bridge id)metal;
    id<CachePressureTesting> cache=[replay valueForKey:@"library_cache"];
    dispatch_queue_t worker=[replay valueForKey:@"worker"];
    __block unsigned loads=0;
    id<MTLLibrary>(^loader)(void)=^id<MTLLibrary>{loads++;return (id)[NSObject new];};
    NSData *hot=[@"hot" dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_sync(worker, ^{
        [cache setAdmissionBytes:8*1024*1024 entries:32];
        for(unsigned i=0;i<12;i++) {
            NSData *key=[[NSString stringWithFormat:@"library-%u",i] dataUsingEncoding:NSUTF8StringEncoding];
            [cache libraryForData:key loader:loader];
        }
        [cache libraryForData:hot loader:loader];assert(cache.count==13);
    });
    for(unsigned warning=0;warning<4;warning++) {
        hv_pvg_metal_trim_memory(metal);
        dispatch_sync(worker, ^{
            assert(cache.count==8); // warning shrinks once; later warnings keep hot entries
            [cache libraryForData:hot loader:loader];assert(loads==13);
        });
    }
    dispatch_sync(worker, ^{[replay setValue:@2 forKey:@"memory_pressure"];});
    hv_pvg_metal_trim_memory(metal);
    dispatch_sync(worker, ^{assert(!cache.count);[replay setValue:@0 forKey:@"memory_pressure"];});
}

/* Populate a real buffer-backed scanout through the replay's object table.
   Runtime access keeps test fixtures out of the production API. Actual present,
   texture creation, snapshot sampling and the legacy framebuffer are exercised. */
static void detachedPresentation(HvPvgMetal *metal) {
    id replay = (__bridge id)metal;
    id<MTLDevice> device = [replay valueForKey:@"device"];
    id<MTLBuffer> buffer = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    assert(buffer && !hv_pvg_lite_old_driver(board.pvg));
    id surface = [NSClassFromString(@"HvObject") new];
    [surface setValue:buffer forKey:@"object"];
    [surface setValue:@YES forKey:@"mapping_in_buffer"];
    [surface setValue:@4 forKey:@"surface_w"]; [surface setValue:@4 forKey:@"surface_h"];
    [surface setValue:@256 forKey:@"row"]; [surface setValue:@0 forKey:@"first"];
    [surface setValue:@((uint32_t)'BGRA') forKey:@"fourcc"];
    Ivar mapped = class_getInstanceVariable([surface class], "mapped"); assert(mapped);
    *(const uint8_t **)((uint8_t *)(__bridge void *)surface + ivar_getOffset(mapped)) = buffer.contents;
    NSMutableDictionary *surfaces = [replay valueForKey:@"surfaces"];
    surfaces[@1] = surface;
    hv_pvg_metal_set_layer(metal, NULL);
    assert(hv_pvg_metal_quiesce(metal) == 0);
    dispatch_queue_t worker = [replay valueForKey:@"worker"];
    for (unsigned i=0; i<32; i++) {
        memset(buffer.contents, (int)(32+i), buffer.length);
        dispatch_sync(worker, ^{
            ((void (*)(id, SEL, uint64_t))objc_msgSend)(replay, sel_registerName("present:"), 1);
        });
        const uint8_t *pixels = NULL; uint32_t width = 0, height = 0;
        assert(hv_pvg_metal_frame(metal, &pixels, &width, &height) == -1);
        uint8_t preview[4]; assert(hv_pvg_metal_snapshot(metal, preview, 1, 1) == 0);
        assert(preview[0] == 32+i && preview[1] == 32+i && preview[2] == 32+i && preview[3] == 255);
    }
}

@protocol ResumeGpuTesting
- (void)commit:(id<MTLCommandBuffer>)buffer channel:(uint32_t)channel stamp:(uint64_t)stamp complete:(BOOL)complete;
@end
static void pointerIvar(id object,const char *name,void *value) {
    Ivar field=class_getInstanceVariable([object class],name);assert(field);
    *(void **)((uint8_t *)(__bridge void *)object+ivar_getOffset(field))=value;
}
/* A private game/browser render target must survive pause, and an unsupported
   resource must refuse the save instead of silently losing its pixels. */
static void privateTextureResume(HvPvgMetal *metal) {
    id replay=(__bridge id)metal;
    dispatch_queue_t worker=[replay valueForKey:@"worker"];
    __block id object=nil;__block id<MTLBuffer> bytes=nil;
    __block BOOL oldCache=NO;__block uint64_t oldEpoch=0;
    dispatch_sync(worker,^{
        id<MTLDevice> device=[replay valueForKey:@"device"];
        bytes=[device newBufferWithLength:16384 options:MTLResourceStorageModeShared];assert(bytes);
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;descriptor.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:descriptor];assert(texture);
        object=[NSClassFromString(@"HvObject")new];
        [object setValue:texture forKey:@"object"];[object setValue:bytes forKey:@"guest_copy"];
        for(NSString *flag in @[@"mapping_in_buffer",@"guest_backed",@"host_valid",@"guest_stale"]) [object setValue:@YES forKey:flag];
        [object setValue:@16384 forKey:@"length"];[object setValue:@1 forKey:@"vpage"];
        [object setValue:@1 forKey:@"tex_mips"];[object setValue:@1 forKey:@"tex_slices"];
        uint32_t *pages=calloc(1,4);assert(pages);pages[0]=1;pointerIvar(object,"pages",pages);pointerIvar(object,"mapped",bytes.contents);
        uint8_t *layout=calloc(1,36);assert(layout);
        uint64_t row=256;uint32_t width=4,height=4,depth=1;
        memcpy(layout+16,&row,8);memcpy(layout+24,&width,4);memcpy(layout+28,&height,4);memcpy(layout+32,&depth,4);
        pointerIvar(object,"tex_layout",layout);
        // This fixture owns an immutable mapping; use the existing exact epoch
        // cache rather than constructing an unrelated guest page-table driver.
        oldCache=[[replay valueForKey:@"batch_cache"]boolValue];oldEpoch=[[replay valueForKey:@"current_epoch"]unsignedLongLongValue];
        [replay setValue:@YES forKey:@"batch_cache"];[replay setValue:@123 forKey:@"current_epoch"];
        [object setValue:@123 forKey:@"refresh_epoch"];[object setValue:@77 forKey:@"refresh_task"];
        NSMutableDictionary *tasks=[replay valueForKey:@"tasks"];tasks[@77]=[NSMutableDictionary dictionaryWithObject:object forKey:@1];
        id<MTLCommandQueue> queue=[replay valueForKey:@"queue"];id<MTLCommandBuffer> cb=[queue commandBuffer];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
        id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:pass];assert(encoder);[encoder endEncoding];
        [(id<ResumeGpuTesting>)replay commit:cb channel:0 stamp:0 complete:NO];
    });
    assert(!hv_pvg_metal_quiesce(metal));
    assert(![[object valueForKey:@"guest_stale"]boolValue]);
    for(unsigned y=0;y<4;y++)for(unsigned x=0;x<4;x++) {
        uint8_t *pixel=(uint8_t *)bytes.contents+y*256+x*4;assert(!pixel[0]&&!pixel[1]&&pixel[2]==255&&pixel[3]==255);
    }
    dispatch_sync(worker,^{[object setValue:@YES forKey:@"guest_stale"];[object setValue:@2 forKey:@"tex_mips"];});
    assert(hv_pvg_metal_quiesce(metal)!=0 && [[object valueForKey:@"guest_stale"]boolValue]);
    dispatch_sync(worker,^{[object setValue:@1 forKey:@"tex_mips"];});
    assert(!hv_pvg_metal_quiesce(metal));
    dispatch_sync(worker,^{
        [[replay valueForKey:@"tasks"]removeObjectForKey:@77];
        [replay setValue:@(oldCache) forKey:@"batch_cache"];[replay setValue:@(oldEpoch) forKey:@"current_epoch"];
    });
    puts("GPU resume: queued private render target preserved; invalid layout refuses save; recovery passed");
}

int main(void) {
    alarm(60);
    char archive_dir[]="/tmp/henge-pipelines-XXXXXX";
    BOOL own_directory=getenv("HV_PVG_ARCHIVE_DIR")==NULL;
    if(own_directory){assert(mkdtemp(archive_dir));setenv("HV_PVG_ARCHIVE_DIR",archive_dir,1);}
    for (int cycle = 0; cycle < 6; cycle++) @autoreleasepool {
        HvCfgParams cfg = {.nr_cpus = 2};
        if (hv_machine_init(&machine, 4 << 20) ||
            hv_vmapple_create(&board, &machine, cpus, 64 << 20, NULL, NULL, &cfg, NULL)) return 1;
        hv_vmapple_reset_cpu(&board);
        HvPvgMetal *metal = hv_pvg_metal_create(board.pvg);
        if (!metal) { fprintf(stderr, "Metal replay unavailable; lifecycle test cannot run\n"); return 1; }
        planarGuestPages(metal);
        archiveCoverage(metal,cycle);
        taskRetirement(metal);
        cachePressure(metal);
        CAMetalLayer *layer = [CAMetalLayer layer];
        hv_pvg_metal_set_layer(metal, (__bridge void *)layer);
        uint64_t timing[4]={0},snapshot[4]={1,2,3,4};
        assert(hv_pvg_metal_gpu_snapshot(NULL,snapshot)==0);
        assert(!snapshot[0]&&!snapshot[1]&&!snapshot[2]&&!snapshot[3]);
        int scope=hv_pvg_metal_gpu_snapshot(metal,snapshot);assert(scope>=1);
        id<MTLDevice> captureDevice=[(__bridge id)metal valueForKey:@"device"];
        assert(snapshot[0]==captureDevice.currentAllocatedSize);
        if(scope==1)assert(!snapshot[1]&&!snapshot[2]&&!snapshot[3]);
        assert(hv_pvg_metal_capture_timing(metal,1,timing)==2);
        for (int i = 0; i < 64; i++) {
            uint32_t *cmd = calloc(6, sizeof *cmd);
            cmd[0] = 0x43; cmd[1] = 24; cmd[2] = i + 1;
            hv_pvg_metal_submit(metal, board.pvg, 0, cmd, 24);
        }
        hv_pvg_metal_trim_memory(metal);
        if (hv_pvg_metal_quiesce(metal)) return 1;
        assert(hv_pvg_metal_capture_timing(metal,-1,timing)==2 && timing[0]>=64);
        assert(![[(__bridge id)metal valueForKey:@"archive_pending"]count] &&
               ![(__bridge id)metal valueForKey:@"archive_save_timer"]);
        assert(![[(__bridge id)metal valueForKey:@"archive_pressure_suspended"]boolValue]);
        (void)hv_pvg_metal_capture_timing(metal,0,NULL);
        privateTextureResume(metal);
        detachedPresentation(metal);
        hv_pvg_metal_set_display_paused(metal, 1);
        assert([[(__bridge id)metal valueForKey:@"display_quiesced"] boolValue]);
        hv_pvg_metal_set_display_paused(metal, 0);
        assert(![[(__bridge id)metal valueForKey:@"display_quiesced"] boolValue]);
        /* Restore distinct glyphs on both ports through the production serializer.
           Readback exercises real Metal textures, including the secondary glyph. */
        size_t size = sizeof(HvDisplaySnapshot) + 2 * 64;
        uint8_t *saved = calloc(1, size), *readback = calloc(1, size);
        if (!saved || !readback) return 1;
        HvDisplaySnapshot *state = (HvDisplaySnapshot *)saved;
        state->version = HV_DISPLAY_SNAPSHOT_VERSION; state->ports = 2;
        for (unsigned port = 0; port < 2; port++) {
            state->port[port] = (HvDisplaySnapshotPort){.width=4,.height=4,.stride=16,
                .shown=1,.hot_x=(int)port,.hot_y=2};
            memset(saved + sizeof *state + port * 64, 0x35 + port, 64);
        }
        if (hv_pvg_metal_set_display_state(metal, saved, size) ||
            hv_pvg_metal_display_state(metal, readback, size) != size || memcmp(saved, readback, size)) {
            fprintf(stderr, "Two-display glyph roundtrip failed\n"); return 1;
        }
        state->port[1].stride = UINT32_MAX;
        if (!hv_pvg_metal_set_display_state(metal, saved, size) ||
            !hv_pvg_metal_set_display_state(metal, readback, size - 1)) return 1;
        /* Invalid input must leave the live renderer untouched. */
        state->port[1].stride = 16;
        if (hv_pvg_metal_display_state(metal, saved, size) != size || memcmp(saved, readback, size)) return 1;
        HvDisplaySnapshot empty = {.version=HV_DISPLAY_SNAPSHOT_VERSION,.ports=2};
        if (hv_pvg_metal_set_display_state(metal, &empty, sizeof empty) ||
            hv_pvg_metal_display_state(metal, NULL, 0) != sizeof empty) return 1;
        free(saved); free(readback);
        hv_pvg_metal_cursor_moved(metal);
        hv_pvg_metal_set_layer(metal, NULL);
        hv_pvg_metal_destroy(metal);
        hv_vmapple_destroy(&board);
        hv_machine_free(&machine);
    }
    if(own_directory){[[NSFileManager defaultManager] removeItemAtPath:@(archive_dir) error:nil];unsetenv("HV_PVG_ARCHIVE_DIR");}
    puts("Metal pipeline archives: render/compute reuse, saved reload, fragmentless bypass, timer cancellation and lifecycle passed");
    puts("Metal lifecycle: 6 cycles, 384 GPU completions drained; both display glyphs restored, malformed input rejected, stale glyphs cleared");
    return 0;
}
