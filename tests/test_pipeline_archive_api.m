/* Independent public Metal API probe: distinguishes a replay integration defect
   from a host adapter that cannot reopen its own binary archives. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc,const char **argv){@autoreleasepool{
 assert(argc==4 || argc==5);BOOL write=!strcmp(argv[3],"write");BOOL mixed=argc==5 && !strcmp(argv[4],"mixed");BOOL compute=argc==5 && !strcmp(argv[4],"compute");id<MTLDevice>d=MTLCreateSystemDefaultDevice();assert(d);
 NSData *bytes=[NSData dataWithContentsOfFile:@(argv[1])];assert(bytes.length);
 dispatch_data_t data=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
 NSError *error=nil;id<MTLLibrary> lib=[d newLibraryWithData:data error:&error];assert(lib);
 MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];p.vertexFunction=[lib newFunctionWithName:@"av"];p.fragmentFunction=[lib newFunctionWithName:@"af"];p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
 MTLComputePipelineDescriptor *cp=[MTLComputePipelineDescriptor new];cp.computeFunction=[lib newFunctionWithName:@"ak"];
 if(argc==5 && (!strcmp(argv[4],"separate")||!strcmp(argv[4],"delayed"))){
  BOOL delayed=!strcmp(argv[4],"delayed");NSMutableArray *archives=[NSMutableArray new];NSMutableArray *urls=[NSMutableArray new];
  unsigned missing_compute=0,missing_render=0;
  NSString *directory=[@(argv[1])stringByDeletingLastPathComponent];
  id<MTLFunction>(^function)(NSString *)=^id<MTLFunction>(NSString *name){
   NSData *single=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"archive_%@.metallib",name]]];assert(single.length);
   dispatch_data_t data=dispatch_data_create(single.bytes,single.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
   NSError *e=nil;id<MTLLibrary> l=[d newLibraryWithData:data error:&e];assert(l && l.functionNames.count==1);return [l newFunctionWithName:name];
  };
  for(unsigned i=0;i<4;i++){
   NSURL *url=[NSURL fileURLWithPath:[NSString stringWithFormat:@"%s-%u",argv[2],i]];
   MTLBinaryArchiveDescriptor *ad=[MTLBinaryArchiveDescriptor new];if(!write)ad.url=url;
   id<MTLBinaryArchive>a=[d newBinaryArchiveWithDescriptor:ad error:&error];assert(a);
   MTLRenderPipelineDescriptor *rp=[MTLRenderPipelineDescriptor new];rp.vertexFunction=function(@"av");rp.fragmentFunction=function(@"af");
   rp.colorAttachments[0].pixelFormat=i==2?MTLPixelFormatRGBA16Float:MTLPixelFormatBGRA8Unorm;
   MTLComputePipelineDescriptor *cp=[MTLComputePipelineDescriptor new];cp.computeFunction=function(i==3?@"ak2":@"ak");
   if(write){BOOL added=i%2?[a addComputePipelineFunctionsWithDescriptor:cp error:&error]:[a addRenderPipelineFunctionsWithDescriptor:rp error:&error];assert(added);}
   rp.binaryArchives=@[a];cp.binaryArchives=@[a];error=nil;
   id state=nil;if(i%2)state=[d newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
   else state=[d newRenderPipelineStateWithDescriptor:rp options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
   printf("Independent separate archives: mode=%s slot=%u write=%d hit=%d error=%s\n",argv[4],i,write,state!=nil,error.localizedDescription.UTF8String ?: "none");
   if(!state){
    /* Only an independently reproduced missing-function result is a known
       adapter capability limit. Creation/add/read/execute errors remain fatal. */
    if(write || ![d.name containsString:@"Paravirtual"] || ![error.localizedDescription containsString:@"Unable to find function"])return 79;
    if(i%2)missing_compute++;else missing_render++;
    rp.binaryArchives=@[];cp.binaryArchives=@[];error=nil;
    if(i%2)state=[d newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionNone reflection:nil error:&error];
    else state=[d newRenderPipelineStateWithDescriptor:rp error:&error];assert(state && !error);
   }
   id<MTLCommandQueue> queue=[d newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];
   id<MTLBuffer> output=nil;
   if(i%2){
    output=[d newBufferWithLength:4 options:MTLResourceStorageModeShared];*(uint32_t *)output.contents=0;
    id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:state];[e setBuffer:output offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];
   }else{
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:rp.colorAttachments[0].pixelFormat width:4 height:4 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> texture=[d newTextureWithDescriptor:td];assert(texture);MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:state];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
   }
   [cb commit];[cb waitUntilCompleted];assert(!cb.error);if(output)assert(*(uint32_t *)output.contents==(i==3?8u:7u));
   [archives addObject:a];[urls addObject:url];
   if(write&&!delayed)assert([a serializeToURL:url error:&error]);
  }
  if(write&&delayed)for(unsigned i=0;i<4;i++)assert([(id<MTLBinaryArchive>)archives[i] serializeToURL:urls[i] error:&error]);
  if(missing_compute||missing_render)printf("Independent adapter archive limit: compute=%u render=%u; all four PSOs executed correctly through checked fallback\n",missing_compute,missing_render);
  return (missing_compute||missing_render)?78:0;
 }
 NSURL *url=[NSURL fileURLWithPath:@(argv[2])];MTLBinaryArchiveDescriptor *ad=[MTLBinaryArchiveDescriptor new];
 if(!write)ad.url=url;
 id<MTLBinaryArchive>a=[d newBinaryArchiveWithDescriptor:ad error:&error];assert(a);
 if(write){
  if(!compute){assert([a addRenderPipelineFunctionsWithDescriptor:p error:&error]);p.binaryArchives=@[a];assert([d newRenderPipelineStateWithDescriptor:p options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error]);}
  if(mixed || compute){assert([a addComputePipelineFunctionsWithDescriptor:cp error:&error]);cp.binaryArchives=@[a];assert([d newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error]);}
  assert([a serializeToURL:url error:&error]);
  printf("Independent Metal archive API: wrote %s mode=%s\n",url.lastPathComponent.UTF8String,mixed?"render+compute":compute?"compute":"render");return 0;
 }
 p.binaryArchives=@[a];cp.binaryArchives=@[a];error=nil;
 id state=nil;
 if(compute){state=[d newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];}
 else{state=[d newRenderPipelineStateWithDescriptor:p options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];}
 printf("Independent Metal archive API: device=%s library_bytes=%lu archive_bytes=%llu reopened_hit=%d error=%s\n",d.name.UTF8String,(unsigned long)bytes.length,[[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil]fileSize],state!=nil,error.localizedDescription.UTF8String ?: "none");
 if(!state){p.binaryArchives=@[];cp.binaryArchives=@[];error=nil;
 if(compute){state=[d newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionNone reflection:nil error:&error];}
 else{state=[d newRenderPipelineStateWithDescriptor:p error:&error];}
 assert(state);puts("Independent Metal archive API: ordinary compilation fallback succeeded");return 78;}
 return 0;
}}
