/* Render a repeatable Core Image matrix on a real Mac and inside the guest.
 * clang -fobjc-arc -framework Foundation -framework CoreImage -framework AppKit
 *       -framework Metal core_image_audit.m -o core-image-audit
 * core-image-audit /path/to/output
 * Compare the RGBA outputs between machines. OS-version differences require
 * review; agreement covers these inputs only, not every shader permutation.
 * kCIContextUseSoftwareRenderer can silently select Metal on Apple Silicon,
 * so it must NOT be used as an independent CPU oracle.
 */
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <Metal/Metal.h>
#include <math.h>

static const int W=256, H=256;
static CIImage *pattern(BOOL second, CGColorSpaceRef cs) {
    NSMutableData *data=[NSMutableData dataWithLength:W*H*4];
    unsigned char *p=data.mutableBytes;
    for(int y=0;y<H;y++) for(int x=0;x<W;x++) {
        int i=(y*W+x)*4;
        int a=64+((x+y)%192);
        p[i]=(second?255-x:x)*a/255;
        p[i+1]=(second?x:y)*a/255;
        p[i+2]=((x/16+y/16)%2?224:32)*a/255;
        p[i+3]=a;
    }
    return [CIImage imageWithBitmapData:data bytesPerRow:W*4 size:CGSizeMake(W,H) format:kCIFormatRGBA8 colorSpace:cs];
}
int runCoreImageAudit(NSString *dir) {
 @autoreleasepool {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device) { fprintf(stderr,"No Metal device; GPU audit cannot run\n");return 3; }
    CIContext *gpu=[CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates:@NO,kCIContextWorkingColorSpace:(__bridge id)cs,kCIContextOutputColorSpace:(__bridge id)cs}];
    CIImage *a=pattern(NO,cs),*b=pattern(YES,cs);
    fprintf(stderr,"GPU device: %s\nGPU context: %s\n",device.name.UTF8String,gpu.description.UTF8String);
    NSArray *names=@[@"CIColorControls",@"CIColorMatrix",@"CIColorInvert",@"CIColorMonochrome",@"CIColorPosterize",@"CIGammaAdjust",@"CIExposureAdjust",@"CIHueAdjust",@"CISepiaTone",@"CIVibrance",@"CITemperatureAndTint",@"CIWhitePointAdjust",@"CIHighlightShadowAdjust",@"CIFalseColor",@"CIPhotoEffectChrome",@"CIPhotoEffectNoir",@"CIVignette",@"CIVignetteEffect",@"CIGaussianBlur",@"CIBoxBlur",@"CIDiscBlur",@"CIMotionBlur",@"CIZoomBlur",@"CIMedianFilter",@"CINoiseReduction",@"CISharpenLuminance",@"CIUnsharpMask",@"CIEdges",@"CIEdgeWork",@"CIGloom",@"CIBloom",@"CICrystallize",@"CIPixellate",@"CIPointillize",@"CIComicEffect",@"CIConvolution3X3",@"CIAffineTransform",@"CILanczosScaleTransform",@"CIBumpDistortion",@"CITwirlDistortion",@"CIPinchDistortion",@"CITorusLensDistortion",@"CIGlassDistortion",@"CIDisplacementDistortion",@"CISourceOverCompositing",@"CISourceInCompositing",@"CISourceOutCompositing",@"CISourceAtopCompositing",@"CIAdditionCompositing",@"CIMultiplyCompositing",@"CIMultiplyBlendMode",@"CIScreenBlendMode",@"CIOverlayBlendMode",@"CIDifferenceBlendMode",@"CIColorBlendMode",@"CIHueBlendMode",@"CISaturationBlendMode",@"CILuminosityBlendMode",@"CIBlendWithMask",@"CIBlendWithAlphaMask",@"CIBlendWithRedMask",@"CILinearGradient",@"CIRadialGradient",@"CICheckerboardGenerator",@"CIStripesGenerator"];
    NSMutableArray *rows=[NSMutableArray new];
    for(NSString *name in names) { @autoreleasepool { @try {
        CIFilter *filter=[CIFilter filterWithName:name];
        if(!filter) { [rows addObject:@{ @"filter":name,@"status":@"unavailable" }];continue; }
        [filter setDefaults];
        for(NSString *key in filter.inputKeys) {
            if([key isEqualToString:@"inputImage"]) [filter setValue:a forKey:key];
            else if([key isEqualToString:@"inputBackgroundImage"]||[key isEqualToString:@"inputShadingImage"]||[key isEqualToString:@"inputTargetImage"]) [filter setValue:b forKey:key];
            else if([key isEqualToString:@"inputMaskImage"]||[key isEqualToString:@"inputDisplacementImage"]) [filter setValue:b forKey:key];
            else if([key isEqualToString:@"inputCenter"]) [filter setValue:[CIVector vectorWithX:128 Y:128] forKey:key];
        }
        if([name isEqualToString:@"CIAffineTransform"]) {
#if TARGET_OS_IOS
            NSValue *transform=[NSValue valueWithCGAffineTransform:CGAffineTransformMake(0.85,0.1,-0.1,0.85,30,10)];
#else
            NSAffineTransform *transform=[NSAffineTransform transform];
            transform.transformStruct=(NSAffineTransformStruct){0.85,0.1,-0.1,0.85,30,10};
#endif
            [filter setValue:transform forKey:@"inputTransform"];
        }
        if([name isEqualToString:@"CIConvolution3X3"]) [filter setValue:[CIVector vectorWithValues:(CGFloat[]){0,-1,0,-1,5,-1,0,-1,0} count:9] forKey:@"inputWeights"];
        CIImage *out=[filter.outputImage imageByCroppingToRect:CGRectMake(0,0,W,H)];
        if(!out) { [rows addObject:@{@"filter":name,@"status":@"no-output"}];continue; }
        NSMutableData *actual=[NSMutableData dataWithLength:W*H*4];
        [gpu render:out toBitmap:actual.mutableBytes rowBytes:W*4 bounds:CGRectMake(0,0,W,H) format:kCIFormatRGBA8 colorSpace:cs];
        unsigned char *v=actual.mutableBytes;
        NSUInteger nz=0;
        for(int i=0;i<W*H*4;i++) if(v[i]) nz++;
        [actual writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".rgba"]] atomically:YES];
        [rows addObject:@{@"filter":name,@"status":@"rendered-needs-reference",@"nonzero":@(nz)}];
        printf("%s nonzero=%lu\n",name.UTF8String,(unsigned long)nz);fflush(stdout);
    } @catch(NSException *e) { [rows addObject:@{@"filter":name,@"status":@"exception",@"error":e.description}]; } } }
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"os":[NSProcessInfo processInfo].operatingSystemVersionString,@"width":@(W),@"height":@(H),@"device":device.name,@"context":gpu.description,@"results":rows} options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[dir stringByAppendingPathComponent:@"results.json"] atomically:YES];
    CGColorSpaceRelease(cs);
 }
 return 0;
}
#ifndef CORE_IMAGE_AUDIT_EMBEDDED
int main(int argc,const char **argv) {
 @autoreleasepool {
    if(argc!=2) { fprintf(stderr,"usage: core-image-audit output-directory\n");return 2; }
    return runCoreImageAudit(@(argv[1]));
 }
}
#endif
