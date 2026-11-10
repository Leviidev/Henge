/* Same source/bytes on the Mac and guest; records raw sRGB RGBA8 output. */
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
static NSString *sha(NSData *d){unsigned char h[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,h);NSMutableString *s=[NSMutableString new];for(unsigned i=0;i<sizeof h;i++)[s appendFormat:@"%02x",h[i]];return s;}
int main(int argc,const char **argv){@autoreleasepool{
 if(argc!=3)return 2;NSString *dir=@(argv[2]);NSError *err=nil;
 if(![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err])return 3;
 NSData *data=[NSData dataWithContentsOfFile:@(argv[1])];CIImage *image=[CIImage imageWithData:data options:@{kCIImageApplyOrientationProperty:@YES}];id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!image||!device)return 4;
 CGFloat scale=512.0/MIN(image.extent.size.width,image.extent.size.height);image=[image imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation((512-image.extent.size.width)/2-image.extent.origin.x,(512-image.extent.size.height)/2-image.extent.origin.y)];
 CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:(__bridge id)cs,kCIContextOutputColorSpace:(__bridge id)cs}];
 NSMutableData *pixels=[NSMutableData dataWithLength:512*512*4];[context render:image toBitmap:pixels.mutableBytes rowBytes:512*4 bounds:CGRectMake(0,0,512,512) format:kCIFormatRGBA8 colorSpace:cs];
 [pixels writeToFile:[dir stringByAppendingPathComponent:@"output.rgba"] atomically:YES];CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);CGImageRef output=CGImageCreate(512,512,8,32,2048,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,provider,NULL,false,kCGRenderingIntentDefault);NSURL *url=[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"output.png"]];CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);CGImageDestinationAddImage(dest,output,NULL);BOOL saved=CGImageDestinationFinalize(dest);CFRelease(dest);CGImageRelease(output);CGDataProviderRelease(provider);CGColorSpaceRelease(cs);
 NSDictionary *report=@{@"schema":@1,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"device":device.name,@"source_sha256":sha(data),@"output_sha256":sha(pixels),@"width":@512,@"height":@512,@"png_saved":@(saved)};NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[dir stringByAppendingPathComponent:@"result.json"] atomically:YES];return saved?0:5;
}}
