/* Compare ImageIO's decoded provider with a CPU bitmap draw. The same binary
 * and source bytes run on the Mac and in the guest. No wallpaper is changed. */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
static NSString *digest(NSData *d) {
    unsigned char h[32]; CC_SHA256(d.bytes,(CC_LONG)d.length,h);
    NSMutableString *s=[NSMutableString new];for(unsigned i=0;i<32;i++)[s appendFormat:@"%02x",h[i]];return s;
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=3)return 2;
    NSString *directory=@(argv[2]);
    if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil])return 3;
    NSData *encoded=[NSData dataWithContentsOfFile:@(argv[1])];
    if(!encoded)return 4;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)encoded,NULL);
    if(!source)return 5;
    NSMutableArray *stages=[NSMutableArray new];
    for(NSString *name in @[@"default",@"float"]) {@autoreleasepool {
        NSDictionary *options=@{(__bridge id)kCGImageSourceShouldCacheImmediately:@YES,
            (__bridge id)kCGImageSourceShouldAllowFloat:@([name isEqualToString:@"float"])};
        CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)options);
        if(!image){[stages addObject:@{@"mode":name,@"error":@"no image"}];continue;}
        CGColorSpaceRef imageSpace=CGImageGetColorSpace(image);
        CFStringRef profile=imageSpace?CGColorSpaceCopyName(imageSpace):NULL;
        NSMutableDictionary *row=[@{@"mode":name,@"width":@(CGImageGetWidth(image)),@"height":@(CGImageGetHeight(image)),
          @"bits_per_component":@(CGImageGetBitsPerComponent(image)),@"bits_per_pixel":@(CGImageGetBitsPerPixel(image)),
          @"row_bytes":@(CGImageGetBytesPerRow(image)),@"bitmap_info":@(CGImageGetBitmapInfo(image)),
          @"color_space":profile?(__bridge NSString *)profile:@"unnamed"} mutableCopy];
        NSData *provider=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
        if(provider){
            const uint8_t *bytes=provider.bytes;uint64_t nonzero=0;uint8_t highest=0;
            for(NSUInteger i=0;i<provider.length;i++){nonzero+=bytes[i]!=0;if(bytes[i]>highest)highest=bytes[i];}
            row[@"provider_bytes"]=@(provider.length);row[@"provider_nonzero_bytes"]=@(nonzero);
            row[@"provider_max_byte"]=@(highest);row[@"provider_sha256"]=digest(provider);
        }
        NSMutableData *pixels=[NSMutableData dataWithLength:512*512*4];
        CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bitmap=CGBitmapContextCreate(pixels.mutableBytes,512,512,8,2048,srgb,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        if(!bitmap)return 6;
        CGContextSetInterpolationQuality(bitmap,kCGInterpolationHigh);
        CGContextDrawImage(bitmap,CGRectMake(0,0,512,512),image);
        row[@"bitmap_sha256"]=digest(pixels);
        [pixels writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".rgba"]] atomically:YES];
        CGImageRef output=CGBitmapContextCreateImage(bitmap);
        NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]];
        CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        CGImageDestinationAddImage(dest,output,NULL);row[@"png_saved"]=@(CGImageDestinationFinalize(dest));
        CFRelease(dest);CGImageRelease(output);CGContextRelease(bitmap);CGColorSpaceRelease(srgb);
        if(profile)CFRelease(profile);CGImageRelease(image);[stages addObject:row];
    }}
    NSDictionary *report=@{@"source_sha256":digest(encoded),@"image_count":@(CGImageSourceGetCount(source)),
       @"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"stages":stages};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[directory stringByAppendingPathComponent:@"result.json"] atomically:YES];
    CFRelease(source);return 0;
}}
