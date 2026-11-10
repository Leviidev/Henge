/* Offline CI archive inspection. Only explicit CUIScaleClamp contract is rendered. */
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
static NSString *Hash(NSData *d){unsigned char h[32];CC_SHA256(d.bytes,(CC_LONG)d.length,h);NSMutableString*s=[NSMutableString new];for(int i=0;i<32;i++)[s appendFormat:@"%02x",h[i]];return s;}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc<2)return 64;NSData *data=[NSData dataWithContentsOfFile:@(argv[1])];NSMutableDictionary *r=[@{@"path":@(argv[1]),@"sha256":data?Hash(data):@"",@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"scope":@"CI enumeration and bounded constructor checks; pixels only when explicit supported oracle requested"} mutableCopy];
    @try {
        NSArray *names=data?[CIKernel kernelNamesFromMetalLibraryData:data]:nil;r[@"ci_names"]=names?:@[];r[@"enumeration_returned"]=@(names!=nil);NSMutableArray *resolved=[NSMutableArray new];r[@"constructor_samples"]=resolved;
        for(NSString *name in [names subarrayWithRange:NSMakeRange(0,MIN(names.count,3))]){NSError *error=nil;CIKernel *kernel=[CIKernel kernelWithFunctionName:name fromMetalLibraryData:data error:&error];[resolved addObject:@{@"name":name,@"resolved":@(kernel!=nil),@"class":kernel?NSStringFromClass(kernel.class):@"none",@"error":error.description?:@""}];}
        if(argc>2&&strcmp(argv[2],"--oracle-cui-scale")==0){
            NSError *error=nil;CIKernel *kernel=[CIKernel kernelWithFunctionName:@"CUIScaleClampKernel" fromMetalLibraryData:data error:&error];r[@"oracle_kernel_resolved"]=@(kernel!=nil);r[@"oracle_error"]=error.description?:@"";id<MTLDevice> device=MTLCreateSystemDefaultDevice();r[@"device"]=device.name?:@"none";
            NSMutableArray *cases=[NSMutableArray new];r[@"oracle_cases"]=cases;const uint8_t input[16]={255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255};
            if(kernel&&device){CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:NSNull.null,kCIContextOutputColorSpace:NSNull.null}];CIImage *image=[CIImage imageWithBitmapData:[NSData dataWithBytes:input length:16] bytesPerRow:8 size:CGSizeMake(2,2) format:kCIFormatRGBA8 colorSpace:nil];
                for(NSNumber *scale in @[@1,@0]){CGRect extent=CGRectMake(0,0,2,2);CIImage *output=[kernel applyWithExtent:extent roiCallback:^CGRect(int i,CGRect rect){return rect;} arguments:@[image,scale]];uint8_t actual[16];memset(actual,0xAA,16);if(output)[context render:output toBitmap:actual rowBytes:8 bounds:extent format:kCIFormatRGBA8 colorSpace:nil];uint8_t expected[16];if(scale.boolValue)memcpy(expected,input,16);else memset(expected,0,16);[cases addObject:@{@"scale":scale,@"output_created":@(output!=nil),@"bytes_checked":@16,@"expected_sha256":Hash([NSData dataWithBytes:expected length:16]),@"actual_sha256":Hash([NSData dataWithBytes:actual length:16]),@"exact":@(output&&memcmp(actual,expected,16)==0)}];}
            }
        }
        r[@"status"]=@"completed_requires_review";
    }@catch(NSException *e){r[@"status"]=@"exception";r[@"exception"]=e.description;}
    NSData *json=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}}
