/* Offline CI archive inspection. Only explicit CUIScaleClamp contract is rendered. */
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
static NSString *Hash(NSData *d){unsigned char h[32];CC_SHA256(d.bytes,(CC_LONG)d.length,h);NSMutableString*s=[NSMutableString new];for(int i=0;i<32;i++)[s appendFormat:@"%02x",h[i]];return s;}

static NSDictionary *Inspect(NSString *path,BOOL oracle){@autoreleasepool{
NSData *data=[NSData dataWithContentsOfFile:path];NSMutableDictionary *r=[@{@"path":path,@"sha256":data?Hash(data):@"",@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"scope":@"CI enumeration and bounded constructor checks; pixels only when explicit supported oracle requested"} mutableCopy];
    @try {
        NSArray *names=data?[CIKernel kernelNamesFromMetalLibraryData:data]:nil;r[@"ci_names"]=names?:@[];r[@"enumeration_returned"]=@(names!=nil);NSMutableArray *resolved=[NSMutableArray new];r[@"constructor_samples"]=resolved;
        for(NSString *name in [names subarrayWithRange:NSMakeRange(0,MIN(names.count,3))]){NSError *error=nil;CIKernel *kernel=[CIKernel kernelWithFunctionName:name fromMetalLibraryData:data error:&error];[resolved addObject:@{@"name":name,@"resolved":@(kernel!=nil),@"class":kernel?NSStringFromClass(kernel.class):@"none",@"error":error.description?:@""}];}
        if(oracle){
            NSError *error=nil;CIKernel *kernel=[CIKernel kernelWithFunctionName:@"CUIScaleClampKernel" fromMetalLibraryData:data error:&error];r[@"oracle_kernel_resolved"]=@(kernel!=nil);r[@"oracle_error"]=error.description?:@"";id<MTLDevice> device=MTLCreateSystemDefaultDevice();r[@"device"]=device.name?:@"none";
            NSMutableArray *cases=[NSMutableArray new];r[@"oracle_cases"]=cases;const uint8_t input[16]={255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255};
            if(kernel&&device){CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:NSNull.null,kCIContextOutputColorSpace:NSNull.null}];CIImage *image=[CIImage imageWithBitmapData:[NSData dataWithBytes:input length:16] bytesPerRow:8 size:CGSizeMake(2,2) format:kCIFormatRGBA8 colorSpace:nil];
                for(NSNumber *scale in @[@1,@0]){CGRect extent=CGRectMake(0,0,2,2);CIImage *output=[kernel applyWithExtent:extent roiCallback:^CGRect(int i,CGRect rect){return rect;} arguments:@[image,scale]];uint8_t actual[16];memset(actual,0xAA,16);if(output)[context render:output toBitmap:actual rowBytes:8 bounds:extent format:kCIFormatRGBA8 colorSpace:nil];uint8_t expected[16];if(scale.boolValue)memcpy(expected,input,16);else memset(expected,0,16);[cases addObject:@{@"scale":scale,@"output_created":@(output!=nil),@"bytes_checked":@16,@"expected_sha256":Hash([NSData dataWithBytes:expected length:16]),@"actual_sha256":Hash([NSData dataWithBytes:actual length:16]),@"exact":@(output&&memcmp(actual,expected,16)==0)}];}
            }
        }
        r[@"status"]=@"completed_requires_review";
    }@catch(NSException *e){r[@"status"]=@"exception";r[@"exception"]=e.description;}
return r;
}}
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include <unistd.h>
static atomic_bool Finished;
static void Save(id value,NSString *path){NSData*d=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];[d writeToFile:path options:NSDataWritingAtomic error:nil];}
static NSDictionary *Run(void){@autoreleasepool{
    NSString *assets=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"AuditAssets"];NSData *bytes=[NSData dataWithContentsOfFile:[assets stringByAppendingPathComponent:@"integrity-jobs.json"]];NSDictionary*m=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
    NSArray *args=NSProcessInfo.processInfo.arguments;NSUInteger idx=[args indexOfObject:@"--integrity-case"];NSString*selection=idx!=NSNotFound&&idx+1<args.count?args[idx+1]:@"";NSString*runID=NSUUID.UUID.UUIDString;
    NSString *base=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"inventory-integrity-03"],*out=[base stringByAppendingPathComponent:runID];[NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];Save(@{@"run_id":runID,@"relative_directory":runID},[base stringByAppendingPathComponent:@"integrity-latest.json"]);
    NSMutableDictionary*r=[@{@"schema":@1,@"kit":@"inventory-integrity-03",@"manifest_sha256":bytes?Hash(bytes):@"",@"run_id":runID,@"selected_case":selection,@"status":@"running",@"shipped_full_library_execution_verified":@NO} mutableCopy];NSString*report=[out stringByAppendingPathComponent:@"integrity-report.json"];Save(r,report);
    NSMutableArray *jobs=[NSMutableArray new];for(NSDictionary*j in m[@"jobs"])if(selection.length&&[j[@"source_sha256"] hasPrefix:selection])[jobs addObject:j];if(jobs.count!=1){r[@"status"]=@"invalid_or_ambiguous_selection";Save(r,report);return r;}
    NSDictionary *job=jobs.firstObject;NSString*file=job[@"file"];NSData *data=[NSData dataWithContentsOfFile:[assets stringByAppendingPathComponent:file]];r[@"source_sha256"]=job[@"source_sha256"];r[@"output_sha256"]=job[@"sha256"];r[@"asset_hash_matches"]=@(data&&[Hash(data)isEqual:job[@"sha256"]]&&[file isEqual:file.lastPathComponent]);if(![r[@"asset_hash_matches"]boolValue]){r[@"status"]=@"asset_hash_failed";Save(r,report);return r;}
    atomic_store(&Finished,false);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{if(!atomic_load(&Finished)){Save(@{@"status":@"watchdog_timeout"},[out stringByAppendingPathComponent:@"integrity-timeout.json"]);_exit(124);}});
    Save(@{@"case":job[@"source_sha256"],@"phase":@"CI_names_constructor_and_optional_contract_oracle"},[out stringByAppendingPathComponent:@"integrity-current.json"]);
    r[@"inspection"]=Inspect([assets stringByAppendingPathComponent:file],[job[@"oracle"]isEqual:@"CUIScaleClampKernel-scale01-2x2"]);r[@"status"]=@"completed_requires_review";atomic_store(&Finished,true);Save(r,report);return r;
}}
@interface IntegrityDelegate:UIResponder<UIApplicationDelegate>
@property(strong,nonatomic)UIWindow *window;
@end
@implementation IntegrityDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;UILabel*l=[[UILabel alloc]initWithFrame:vc.view.bounds];l.numberOfLines=0;l.textAlignment=NSTextAlignmentCenter;l.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;l.text=@"Core Image integrity probe\nOne bounded archive";[vc.view addSubview:l];self.window.rootViewController=vc;[self.window makeKeyAndVisible];app.idleTimerDisabled=YES;dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSDictionary*r=Run();dispatch_async(dispatch_get_main_queue(),^{l.text=[NSString stringWithFormat:@"Core Image integrity probe\n%@\nReview evidence separately",r[@"status"]];app.idleTimerDisabled=NO;});});return YES;}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(IntegrityDelegate.class));}}
