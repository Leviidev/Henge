/* One explicitly selected library per launch. No guessed function constants/pipelines. */
#define main RadarOracleCLI
#define Hash RadarHash
#include "shader_inventory_device_radar_oracle.m"
#undef Hash
#undef main
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#define EXPANSION_PLATFORM @"ios"
#else
#import <AppKit/AppKit.h>
#define EXPANSION_PLATFORM @"macos"
#endif
#include <stdatomic.h>
#include <unistd.h>
static atomic_bool ExpansionDone;
static NSString*ExpansionRoot;
static void ExpansionSave(id r,NSString*name){NSData*d=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];[d writeToFile:[ExpansionRoot stringByAppendingPathComponent:name]options:NSDataWritingAtomic error:nil];}
static NSDictionary*ExpansionRun(NSString*assets,NSString*out,NSString*selected){@autoreleasepool{
    NSString*uid=NSUUID.UUID.UUIDString;ExpansionRoot=[out stringByAppendingPathComponent:uid];[NSFileManager.defaultManager createDirectoryAtPath:ExpansionRoot withIntermediateDirectories:YES attributes:nil error:nil];NSData*latest=[NSJSONSerialization dataWithJSONObject:@{@"run_id":uid,@"relative_directory":uid}options:0 error:nil];[latest writeToFile:[out stringByAppendingPathComponent:@"expansion-latest.json"]atomically:YES];NSData*mb=[NSData dataWithContentsOfFile:[assets stringByAppendingPathComponent:@"expansion-jobs.json"]];NSDictionary*m=mb?[NSJSONSerialization JSONObjectWithData:mb options:0 error:nil]:nil;NSMutableDictionary*r=[@{@"schema":@1,@"kit":@"inventory-expansion-ipad-03",@"run_id":uid,@"manifest_sha256":mb?RadarHash(mb):@"",@"selected":selected?:@"",@"status":@"started",@"explicit_metal_pipeline_creation_attempted":@NO,@"runtime_platform":EXPANSION_PLATFORM,@"os":NSProcessInfo.processInfo.operatingSystemVersionString}mutableCopy];ExpansionSave(r,@"expansion-report.json");
    NSMutableArray*matches=[NSMutableArray new];if(selected.length)for(NSDictionary*job in m[@"libraries"])if([job[@"id"]hasPrefix:selected])[matches addObject:job];if(matches.count!=1){r[@"status"]=@"selection_required_or_ambiguous";ExpansionSave(r,@"expansion-report.json");return r;}NSDictionary*j=matches[0];r[@"source_sha256"]=j[@"source_sha256"];r[@"candidate_sha256"]=j[@"candidate_sha256"];r[@"kind"]=j[@"kind"];r[@"owner_role"]=j[@"owner_role"];
    atomic_store(&ExpansionDone,false);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{if(!atomic_load(&ExpansionDone)){ExpansionSave(@{@"status":@"watchdog_timeout",@"selected":selected?:@""},@"expansion-timeout.json");_exit(124);}});
    @try{NSString*file=j[@"file"];NSString*path=[assets stringByAppendingPathComponent:file];NSData*b=[NSData dataWithContentsOfFile:path];BOOL valid=[file isEqual:file.lastPathComponent]&&b&&[RadarHash(b)isEqual:j[@"candidate_sha256"]]&&b.length==[j[@"byte_size"]unsignedLongLongValue];r[@"asset_verified"]=@(valid);if(!valid){r[@"status"]=@"asset_verification_failed";atomic_store(&ExpansionDone,true);ExpansionSave(r,@"expansion-report.json");return r;}
        if([j[@"kind"]isEqual:@"metal"]){id<MTLDevice>dev=MTLCreateSystemDefaultDevice();r[@"device"]=dev.name?:@"none";NSError*e=nil;dispatch_data_t bytes=dispatch_data_create(b.bytes,b.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);id<MTLLibrary>lib=[dev newLibraryWithData:bytes error:&e];r[@"library_loaded"]=@(lib!=nil);r[@"library_error"]=e.description?:@"";NSMutableArray*functions=[NSMutableArray new];r[@"functions"]=functions;
            for(NSString*name in [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]){@autoreleasepool{NSMutableDictionary*f=[@{@"name":name,@"constants":[NSMutableArray new]}mutableCopy];@try{id<MTLFunction>fn=[lib newFunctionWithName:name];f[@"created"]=@(fn!=nil);f[@"type"]=fn?@(fn.functionType):@0;for(NSString*key in [fn.functionConstantsDictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]){MTLFunctionConstant*c=fn.functionConstantsDictionary[key];[f[@"constants"]addObject:@{@"name":c.name,@"index":@(c.index),@"type":@(c.type),@"required":@(c.required)}];}}@catch(NSException*x){f[@"exception"]=x.description;}[functions addObject:f];}}
            r[@"function_records_equal"]=@([functions isEqualToArray:j[@"expected_functions"]]);r[@"function_count"]=@(functions.count);r[@"execution_scope"]=@"library load, unspecialized function creation, names/types/constant metadata; no pipelines or pixels";
        }else if([j[@"kind"]isEqual:@"coreimage"]){NSArray*names=[CIKernel kernelNamesFromMetalLibraryData:b];r[@"ci_names"]=names?:@[];r[@"ci_names_equal"]=@([names isEqualToArray:j[@"expected_ci_names"]]);NSError*e=nil;CIKernel*k=[CIKernel kernelWithFunctionName:@"radarSelectHashKernel" fromMetalLibraryData:b error:&e];r[@"ci_kernel_resolved"]=@(k!=nil);r[@"ci_error"]=e.description?:@"";NSString*report=[ExpansionRoot stringByAppendingPathComponent:@"radar-oracle.json"];const char*args[]={"radar-oracle",path.fileSystemRepresentation,report.fileSystemRepresentation};int code=RadarOracleCLI(3,args);r[@"coreimage_execution_attempted"]=@YES;r[@"oracle_returncode"]=@(code);NSData*d=[NSData dataWithContentsOfFile:report];r[@"oracle"]=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:@{};r[@"execution_scope"]=@"validated two-sampler2x2 synthetic oracle; HASH semantics remains separately reviewed";}else r[@"unsupported_kind"]=j[@"kind"]?:@"missing";
        r[@"status"]=@"completed_requires_review";
    }@catch(NSException*e){r[@"status"]=@"exception";r[@"exception"]=e.description;}atomic_store(&ExpansionDone,true);ExpansionSave(r,@"expansion-report.json");return r;
}}
#if TARGET_OS_IOS
@interface ExpansionDelegate:UIResponder<UIApplicationDelegate>
@property(strong,nonatomic)UIWindow*window;
@end
@implementation ExpansionDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;UILabel*l=[[UILabel alloc]initWithFrame:vc.view.bounds];l.numberOfLines=0;l.textAlignment=NSTextAlignmentCenter;l.text=@"Expansion library audit\nOne selected library per launch";[vc.view addSubview:l];self.window.rootViewController=vc;[self.window makeKeyAndVisible];NSArray*args=NSProcessInfo.processInfo.arguments;NSUInteger i=[args indexOfObject:@"--library"];NSString*selected=(i!=NSNotFound&&i+1<args.count)?args[i+1]:nil;app.idleTimerDisabled=YES;dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSDictionary*r=ExpansionRun([NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"AuditAssets"],[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"inventory-expansion-ipad-03"],selected);dispatch_async(dispatch_get_main_queue(),^{l.text=[NSString stringWithFormat:@"Expansion audit\n%@\n%@",r[@"selected"],r[@"status"]];app.idleTimerDisabled=NO;});});return YES;}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ExpansionDelegate.class));}}
#else
int main(int argc,const char**argv){@autoreleasepool{if(argc!=4)return 64;NSApplicationLoad();NSDictionary*r=ExpansionRun(@(argv[1]),@(argv[2]),@(argv[3]));return[r[@"status"]isEqual:@"completed_requires_review"]?0:1;}}
#endif
