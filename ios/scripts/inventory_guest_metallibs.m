/* Inventory explicit shader files, with optional native Metal metadata loading.
 * This does not create pipelines or prove rendered output. File-search scope and
 * search errors are supplied separately by the caller; embedded blobs and
 * dynamically generated programs are not claimed to be enumerated here.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=3 && argc!=4){fprintf(stderr,"usage: inventory-guest-metallibs file-list.txt output.json [--export]\n");return 2;}
    BOOL export=argc==4 && !strcmp(argv[3],"--export");
    if(argc==4 && !export)return 2;
    NSError *error=nil;
    NSString *list=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    if(!list){fprintf(stderr,"%s\n",error.description.UTF8String);return 2;}
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device)device=MTLCopyAllDevices().firstObject;
    NSString *exportDir=[[@(argv[2]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shipped-artifacts"];
    if(export)[[NSFileManager defaultManager] createDirectoryAtPath:exportDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *files=[NSMutableArray new],*libraries=[NSMutableArray new];
    NSMutableDictionary *byHash=[NSMutableDictionary new];
    for(NSString *path in [list componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) { @autoreleasepool {
        if(!path.length)continue;
        NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
        NSMutableDictionary *file=[@{@"path":path,@"size":attrs[NSFileSize]?:@0} mutableCopy];
        [files addObject:file];
        // Inventory large files too, but record why native loading was skipped.
        if(!attrs || [attrs[NSFileSize] unsignedLongLongValue]>(256ull<<20)) {
            file[@"status"]=attrs?@"over-256MiB-loading-limit":@"stat-failed";
            if(!attrs)file[@"error"]=error.description?:@"unknown";
            continue;
        }
        NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
        if(!data){file[@"status"]=@"read-failed";file[@"error"]=error.description?:@"unknown";continue;}
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
        NSMutableString *digest=[NSMutableString new];for(unsigned i=0;i<sizeof hash;i++)[digest appendFormat:@"%02x",hash[i]];
        file[@"sha256"]=digest;file[@"status"]=@"inventoried";
        NSMutableDictionary *entry=byHash[digest];
        if(entry){[entry[@"paths"] addObject:path];continue;}
        entry=[@{@"sha256":digest,@"size":@(data.length),@"paths":[NSMutableArray arrayWithObject:path]} mutableCopy];
        byHash[digest]=entry;[libraries addObject:entry];
        if(export) {
            NSString *artifact=[digest stringByAppendingPathExtension:path.pathExtension];
            if([data writeToFile:[exportDir stringByAppendingPathComponent:artifact] options:NSDataWritingAtomic error:&error])entry[@"artifact_file"]=artifact;
            else entry[@"export_error"]=error.description?:@"unknown";
        }
        if(data.length<4 || memcmp(data.bytes,"MTLB",4)) {
            entry[@"status"]=@"non-MTLB-container";continue;
        }
        if(!device){entry[@"status"]=@"no-Metal-device";continue;}
        error=nil;
        id<MTLLibrary> library=[device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
        if(!library){entry[@"status"]=@"guest-library-load-failed";entry[@"error"]=error.description?:@"unknown";continue;}
        entry[@"status"]=@"guest-metadata-loaded";
        entry[@"function_names"]=library.functionNames;
        NSMutableArray *functions=[NSMutableArray new];
        for(NSString *name in library.functionNames)
            [functions addObject:@{@"name":name,@"status":@"name-enumerated-only"}];
        entry[@"functions"]=functions;
        printf("%s: %lu functions, %lu bytes\n",path.UTF8String,(unsigned long)functions.count,(unsigned long)data.length);fflush(stdout);
    } }
    NSDictionary *result=@{@"schema":@1,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"device":device.name?:@"none",@"files":files,@"libraries":libraries,@"limits":@[@"Only explicit paths from the supplied file search are included",@"Embedded libraries and future runtime-generated variants are not covered",@"Function names are enumerated without instantiating private function types",@"Metadata loading is not pipeline creation or execution",@"Files over 256 MiB are listed but not loaded or hashed"]};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    if(!json || ![json writeToFile:@(argv[2]) options:NSDataWritingAtomic error:&error]){fprintf(stderr,"%s\n",error.description.UTF8String);return 2;}
    printf("Inventory complete: %lu paths, %lu unique readable artifacts\n",(unsigned long)files.count,(unsigned long)libraries.count);
}return 0;}
