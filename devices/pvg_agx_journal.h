#ifndef HV_PVG_AGX_JOURNAL_H
#define HV_PVG_AGX_JOURNAL_H
/* Opt-in diagnostics for ordinary compilation. Does not alter Metal input,
 * retain libraries/functions, serialize compilation, or dispatch GPU work. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include <unistd.h>

static NSString *hv_agx_documents(void) {
#ifdef HV_AGX_TEST_ROOT
    return HV_AGX_TEST_ROOT;
#else
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
#endif
}
static BOOL hv_agx_enabled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:[hv_agx_documents() stringByAppendingPathComponent:@"agx-journal-enable"]];
}
static NSString *hv_agx_hash(NSData *d) {
    unsigned char b[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes,(CC_LONG)d.length,b);
    NSMutableString *s=[NSMutableString new];
    for(unsigned i=0;i<sizeof b;i++)[s appendFormat:@"%02x",b[i]];
    return s;
}
static NSObject *hv_agx_guard(void) {
    static NSObject *guard;static dispatch_once_t once;
    dispatch_once(&once,^{guard=[NSObject new];});return guard;
}
static NSString *hv_agx_image_uuid(const struct mach_header *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"unknown";
    const uint8_t *p = (const uint8_t *)header + sizeof(struct mach_header_64);
    const uint8_t *end = p + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && (size_t)(end - p) >= sizeof(struct load_command); i++) {
        const struct load_command *command = (const void *)p;
        if (command->cmdsize < sizeof *command || command->cmdsize > (size_t)(end - p)) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command))
            return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
        p += command->cmdsize;
    }
    return @"unknown";
}

static NSDictionary *hv_agx_identity(void) {
    static NSDictionary *identity;static dispatch_once_t once;
    dispatch_once(&once,^{
        /* An injected image can occupy dyld index zero. Resolve this code's
           actual image first; in debug builds it can be in a dylib. */
        Dl_info info = {0};
        const struct mach_header *renderer = dladdr((const void *)&hv_agx_identity, &info)
            ? (const struct mach_header *)info.dli_fbase : NULL;
        const struct mach_header *executable = renderer;
        if (!executable || executable->filetype != MH_EXECUTE) {
            executable = NULL;
            uint32_t count = _dyld_image_count();
            for (uint32_t i = 0; i < count; i++) {
                const struct mach_header *candidate = _dyld_get_image_header(i);
                if (candidate && candidate->filetype == MH_EXECUTE) {
                    executable = candidate;
                    break;
                }
            }
        }
        identity=@{@"executable_uuid":hv_agx_image_uuid(executable),
            @"renderer_image_uuid":hv_agx_image_uuid(renderer),@"bundle_id":NSBundle.mainBundle.bundleIdentifier?:@"",
            @"bundle_version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@""};
    });return identity;
}
/* Guard protects I/O accounting only. No Metal getter/compiler call under it. */
static NSString *hv_agx_session_locked(void) {
    static NSString *session;
    if(!session) {
        NSString *root=[hv_agx_documents() stringByAppendingPathComponent:@"agx-journal"];
        NSString *candidate=[root stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%d-%@",getpid(),NSUUID.UUID.UUIDString]];
        if([NSFileManager.defaultManager createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:nil]) session=candidate;
        if(session) [[session.lastPathComponent dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:[root stringByAppendingPathComponent:@"latest-session.txt"] options:NSDataWritingAtomic error:nil];
    }
    return session;
}
static NSDictionary *hv_agx_blob(NSData *bytes,NSString *kind) {
    if(!hv_agx_enabled())return nil;
    if(!bytes || bytes.length>32*1024*1024)return @{@"archive_status":@"size_limit"};
    NSString *hash=hv_agx_hash(bytes);
    NSMutableDictionary *r=[@{@"sha256":hash,@"bytes":@(bytes.length),@"kind":kind}mutableCopy];
    @synchronized(hv_agx_guard()) {
        static NSUInteger total, files;
        NSString *session=hv_agx_session_locked();
        NSString *name=[hash stringByAppendingPathExtension:[kind isEqual:@"library"]?@"metallib":@"bin"];
        NSString *path=[session stringByAppendingPathComponent:name];
        if(!session)r[@"archive_status"]=@"directory_failed";
        else if([NSFileManager.defaultManager fileExistsAtPath:path]) {
            NSData *old=[NSData dataWithContentsOfFile:path];
            r[@"archive_status"]=[old isEqual:bytes]?@"saved":@"existing_bytes_differ";
        } else if(files>=4096 || bytes.length>64*1024*1024-total)r[@"archive_status"]=@"budget_exhausted";
        else if([bytes writeToFile:path options:NSDataWritingAtomic error:nil]) {
            files++;total+=bytes.length;r[@"archive_status"]=@"saved";
        } else r[@"archive_status"]=@"write_failed";
        if(session){r[@"session"]=session.lastPathComponent;r[@"file"]=name;}
    }
    return r;
}
static NSDictionary *hv_agx_library(NSData *bytes,NSString *source,NSString *route) {
    @try {
        NSMutableDictionary *r=[hv_agx_blob(bytes,@"library") mutableCopy];
        if(r){r[@"source_sha256"]=source?:@"unknown";r[@"route"]=route?:@"unknown";}
        return r;
    } @catch(NSException *exception) {
        return @{@"archive_status":@"capture_exception",@"exception":exception.name};
    }
}
static void hv_agx_bind(id function,NSDictionary *provenance) {
    if(function && provenance)objc_setAssociatedObject(function,"hvAGXProvenance",provenance,OBJC_ASSOCIATION_COPY_NONATOMIC);
}
static NSDictionary *hv_agx_function(id<MTLFunction> f) {
    if(!f)return @{@"present":@NO};
    return @{@"present":@YES,@"name":f.name?:@"",@"type":@(f.functionType),
        @"class":NSStringFromClass([(id)f class]),@"object_address":[NSString stringWithFormat:@"%p",(__bridge void*)f],
        @"library_identity":objc_getAssociatedObject(f,"hvLibraryID")?:@"unknown",
        @"selected_bytes":objc_getAssociatedObject(f,"hvAGXProvenance")?:@{@"archive_status":@"not_observed"}};
}
static NSDictionary *hv_agx_descriptor(id d,uint32_t tag) {
    if(!d)return @{};
    NSMutableDictionary *r=[@{@"class":NSStringFromClass([d class]),
        @"object_address":[NSString stringWithFormat:@"%p",(__bridge void*)d]}mutableCopy];
    if(tag==14) {
        MTLRenderPipelineDescriptor *p=d;NSMutableArray *attrs=[NSMutableArray new],*layouts=[NSMutableArray new],*colors=[NSMutableArray new];
        r[@"vertex"]=hv_agx_function(p.vertexFunction);r[@"fragment"]=hv_agx_function(p.fragmentFunction);
        r[@"samples"]=@(p.rasterSampleCount);r[@"depth"]=@(p.depthAttachmentPixelFormat);r[@"stencil"]=@(p.stencilAttachmentPixelFormat);
        for(NSUInteger i=0;i<31;i++) {
            MTLVertexAttributeDescriptor *a=p.vertexDescriptor.attributes[i];
            if(a && a.format!=MTLVertexFormatInvalid)[attrs addObject:@{@"index":@(i),@"format":@(a.format),@"buffer":@(a.bufferIndex),@"offset":@(a.offset)}];
            MTLVertexBufferLayoutDescriptor *l=p.vertexDescriptor.layouts[i];
            if(l && l.stride)[layouts addObject:@{@"index":@(i),@"stride":@(l.stride),@"step":@(l.stepFunction),@"rate":@(l.stepRate)}];
        }
        for(NSUInteger i=0;i<8;i++){MTLRenderPipelineColorAttachmentDescriptor *c=p.colorAttachments[i];
            [colors addObject:@{@"index":@(i),@"format":@(c.pixelFormat),@"blend":@(c.blendingEnabled),@"mask":@(c.writeMask)}];}
        r[@"attributes"]=attrs;r[@"layouts"]=layouts;r[@"colors"]=colors;
    } else if(tag==51) {
        MTLTileRenderPipelineDescriptor *p=d;r[@"tile"]=hv_agx_function(p.tileFunction);r[@"samples"]=@(p.rasterSampleCount);
    } else if(tag==11)r[@"compute"]=hv_agx_function(((MTLComputePipelineDescriptor*)d).computeFunction);
    r[@"scope"]=@"public field subset; raw descriptor retained; private ABI/driver heap not inspected";
    return r;
}
static NSMutableDictionary *hv_agx_begin(NSData *raw,uint32_t tag,uint32_t task) {
    if(!hv_agx_enabled())return nil;
    if(raw.length>1024*1024)return nil;
    @try {
    return [@{@"schema":@1,@"attempt":NSUUID.UUID.UUIDString,@"pid":@(getpid()),@"tag":@(tag),@"task":@(task),
        @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"executable_identity":hv_agx_identity(),
        @"serialized":hv_agx_blob(raw,@"descriptor")?:@{},
        @"ownership_scope":@"normal ARC object table + local descriptor; journal holds strings/numbers/bytes only, no extra Metal object retention"}mutableCopy];
    } @catch(NSException *exception) {
        fprintf(stderr,"hengevm: agx-journal: begin unavailable: %s\n",exception.name.UTF8String);
        return nil;
    }
}
static void hv_agx_phase(NSMutableDictionary *attempt,id descriptor,NSDictionary *refs,NSString *phase,NSError *error) {
    if(!attempt || !hv_agx_enabled())return;
    @try {
        NSMutableDictionary *r=[attempt mutableCopy];r[@"phase"]=phase;r[@"timestamp"]=@([NSDate date].timeIntervalSince1970);
        r[@"descriptor"]=hv_agx_descriptor(descriptor,[attempt[@"tag"] unsignedIntValue]);
        r[@"deserialization_bindings"]=refs?:@{};r[@"error"]=error.description?:@"";
        @synchronized(hv_agx_guard()) {
            static uint64_t sequence;
            r[@"sequence"]=@(++sequence);
            NSData *json=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:nil];
            NSString *session=hv_agx_session_locked();
            if(json.length<=256*1024 && session) {
                NSString *slot=[NSString stringWithFormat:@"event-%03llu.json",(unsigned long long)(sequence%128)];
                BOOL saved=[json writeToFile:[session stringByAppendingPathComponent:slot] options:NSDataWritingAtomic error:nil];
                BOOL latest=[json writeToFile:[session stringByAppendingPathComponent:@"latest.json"] options:NSDataWritingAtomic error:nil];
                if(!saved || !latest)fprintf(stderr,"hengevm: agx-journal: event write unavailable\n");
            }
        }
    } @catch(NSException *exception) {
        fprintf(stderr,"hengevm: agx-journal: capture unavailable: %s\n",exception.name.UTF8String);
    }
}
#endif
