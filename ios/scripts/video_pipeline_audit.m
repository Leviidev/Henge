/* Cross-platform macOS reference/guest diagnostic. No injected GL workaround.
 * VT output -> explicit Metal Core Image context -> RGBA8 oracle, plus a separate
 * AVPlayer readiness/output probe. A decoded buffer is never counted as proof
 * of correct pixels or successful player playback. */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *hashBytes(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *value=[NSMutableString new];
    for(unsigned i=0;i<sizeof bytes;i++)[value appendFormat:@"%02x",bytes[i]];
    return value;
}
static void writeJSON(id value,NSString *path) {
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil]
     writeToFile:path options:NSDataWritingAtomic error:nil];
}
static id errorJSON(NSError *error) {
    if(!error)return NSNull.null;
    NSMutableDictionary *value=[@{@"domain":error.domain,@"code":@(error.code),@"description":error.localizedDescription,
        @"userInfo":error.userInfo.description?:@""} mutableCopy];
    if(error.userInfo[NSUnderlyingErrorKey])value[@"underlying"]=errorJSON(error.userInfo[NSUnderlyingErrorKey]);
    return value;
}
static NSString *fourcc(OSType code) {
    return [NSString stringWithFormat:@"%c%c%c%c",(code>>24)&255,(code>>16)&255,(code>>8)&255,code&255];
}

@interface VideoAudit : NSObject
@property(strong) CIContext *context;
@property(strong) NSString *root;
@property(strong) NSMutableArray *frames;
@property(strong) NSMutableArray *errors;
@property unsigned expectedFrames;
@property unsigned frameLimit;
@property OSType format;
@end
@implementation VideoAudit
@end

static void decoded(void *ref,void *source,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime pts,CMTime duration) {
    @autoreleasepool {
        VideoAudit *audit=(__bridge VideoAudit *)ref;
        @synchronized(audit) {
        if(status || !image){[audit.errors addObject:@{@"status":@(status),@"image_present":@(image!=NULL),@"flags":@(flags)}];return;}
        unsigned index=(unsigned)audit.frames.count;
        size_t width=CVPixelBufferGetWidth(image),height=CVPixelBufferGetHeight(image);
        OSType format=CVPixelBufferGetPixelFormatType(image);
        BOOL save=audit.frameLimit ? index==0 : (index<3 || index%30==0 || index+1==audit.expectedFrames);
        NSString *stem=[NSString stringWithFormat:@"frame-%04u",index];
        NSMutableDictionary *row=[@{@"index":@(index),@"pts_value":@(pts.value),@"pts_scale":@(pts.timescale),
          @"width":@(width),@"height":@(height),@"format":fourcc(format),@"flags":@(flags),
          @"iosurface":@(CVPixelBufferGetIOSurface(image)!=NULL)} mutableCopy];
        if(format!=audit.format){row[@"error"]=@"unexpected pixel format";[audit.frames addObject:row];return;}
        if(width>4096 || height>4096 || !width || !height){row[@"error"]=@"unexpected dimensions";[audit.frames addObject:row];return;}
        NSMutableArray *planes=[NSMutableArray new];
        CVReturn lock=CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
        if(lock){row[@"error"]=[NSString stringWithFormat:@"pixel lock failed %d",lock];[audit.frames addObject:row];return;}
        BOOL planar=CVPixelBufferIsPlanar(image),ten=format==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        size_t count=planar?CVPixelBufferGetPlaneCount(image):1;
        for(size_t plane=0;plane<count;plane++) {
            size_t pw=planar?CVPixelBufferGetWidthOfPlane(image,plane):width;
            size_t ph=planar?CVPixelBufferGetHeightOfPlane(image,plane):height;
            size_t stride=planar?CVPixelBufferGetBytesPerRowOfPlane(image,plane):CVPixelBufferGetBytesPerRow(image);
            size_t packed=pw*(planar?(plane?2:1)*(ten?2:1):4);
            const uint8_t *base=planar?CVPixelBufferGetBaseAddressOfPlane(image,plane):CVPixelBufferGetBaseAddress(image);
            if(!base || packed>stride){row[@"error"]=@"invalid plane layout";break;}
            NSMutableData *data=[NSMutableData dataWithLength:packed*ph];
            for(size_t y=0;y<ph;y++)memcpy((uint8_t *)data.mutableBytes+y*packed,base+y*stride,packed);
            NSMutableDictionary *p=[@{@"plane":@(plane),@"width":@(pw),@"height":@(ph),@"row_bytes":@(packed),@"sha256":hashBytes(data)} mutableCopy];
            if(save){NSString *name=[NSString stringWithFormat:@"%@-plane-%zu.bin",stem,plane];[data writeToFile:[audit.root stringByAppendingPathComponent:name] atomically:YES];p[@"file"]=name;}
            [planes addObject:p];
        }
        CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
        row[@"planes"]=planes;
        CIImage *ci=[CIImage imageWithCVPixelBuffer:image];
        NSMutableData *rgba=[NSMutableData dataWithLength:width*height*4];
        memset(rgba.mutableBytes,0xA5,rgba.length);
        CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        @try {
            [audit.context render:ci toBitmap:rgba.mutableBytes rowBytes:width*4 bounds:CGRectMake(0,0,width,height) format:kCIFormatRGBA8 colorSpace:srgb];
            row[@"rgba_sha256"]=hashBytes(rgba);
            if(save){NSString *name=[stem stringByAppendingString:@".rgba"];[rgba writeToFile:[audit.root stringByAppendingPathComponent:name] atomically:YES];row[@"rgba_file"]=name;}
        } @catch(NSException *exception) {row[@"error"]=exception.description;}
        CGColorSpaceRelease(srgb);
        [audit.frames addObject:row];
        if(index%30==0)fprintf(stderr,"video-audit: rendered frame %u format=%s\n",index,fourcc(format).UTF8String);
        }
    }
}

static NSDictionary *playerProbe(NSURL *url) {
    AVPlayerItem *item=[AVPlayerItem playerItemWithURL:url];
    AVPlayerItemVideoOutput *output=[[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:
        @{(__bridge id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
    [item addOutput:output]; AVPlayer *player=[AVPlayer playerWithPlayerItem:item];
    player.volume=0; // decoded audio is tested separately; do not claim audible output
    player.automaticallyWaitsToMinimizeStalling=NO;
    [player play];
    double started=NSProcessInfo.processInfo.systemUptime;
    NSUInteger frames=0;double last=-1;NSMutableArray *samples=[NSMutableArray new];
    while(NSProcessInfo.processInfo.systemUptime-started<15) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        if(item.status==AVPlayerItemStatusFailed)break;
        CMTime now=item.currentTime;
        if([output hasNewPixelBufferForItemTime:now]) {
            CMTime display;CVPixelBufferRef pixel=[output copyPixelBufferForItemTime:now itemTimeForDisplay:&display];
            if(pixel){frames++;if(samples.count<4)[samples addObject:@{@"time":@(CMTimeGetSeconds(display)),@"width":@(CVPixelBufferGetWidth(pixel)),@"height":@(CVPixelBufferGetHeight(pixel))}];CVPixelBufferRelease(pixel);}
        }
        double t=CMTimeGetSeconds(now);if(isfinite(t))last=t;
        if(isfinite(CMTimeGetSeconds(item.duration)) && last>=CMTimeGetSeconds(item.duration)-.02)break;
    }
    [player pause];
    return @{@"item_status":@(item.status),@"item_error":errorJSON(item.error),@"player_error":errorJSON(player.error),
        @"time_seconds":@(last),@"video_output_buffers":@(frames),@"samples":samples,
        @"waiting_reason":player.reasonForWaitingToPlay?:@"",@"error_log":item.errorLog.description?:@"",
        @"audible_output_tested":@NO};
}

static NSDictionary *audioProbe(AVAsset *asset,NSString *root) {
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if(!track)return @{@"status":@"no_audio_track"};
    NSError *error=nil;AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:
        @{AVFormatIDKey:@(kAudioFormatLinearPCM),AVLinearPCMBitDepthKey:@32,AVLinearPCMIsFloatKey:@YES,AVLinearPCMIsNonInterleaved:@NO}];
    [reader addOutput:output];[reader startReading];
    NSMutableData *pcm=[NSMutableData new];size_t frames=0;CMSampleBufferRef sample;
    while((sample=[output copyNextSampleBuffer])) {
        CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);size_t length=block?CMBlockBufferGetDataLength(block):0;
        if(pcm.length+length>16*1024*1024){CFRelease(sample);[reader cancelReading];break;}
        NSUInteger offset=pcm.length;[pcm increaseLengthBy:length];
        if(length)CMBlockBufferCopyDataBytes(block,0,length,(uint8_t *)pcm.mutableBytes+offset);
        frames+=CMSampleBufferGetNumSamples(sample);CFRelease(sample);
    }
    [pcm writeToFile:[root stringByAppendingPathComponent:@"audio.f32"] atomically:YES];
    double sum=0;float peak=0;const float *values=pcm.bytes;
    for(size_t i=0;i<pcm.length/sizeof(float);i++){sum+=(double)values[i]*values[i];peak=fmaxf(peak,fabsf(values[i]));}
    return @{@"reader_status":@(reader.status),@"error":errorJSON(reader.error),@"frames":@(frames),@"bytes":@(pcm.length),
        @"sha256":hashBytes(pcm),@"rms":@(pcm.length?sqrt(sum/(pcm.length/sizeof(float))):0),@"peak":@(peak)};
}

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=5 && argc!=6){fprintf(stderr,"usage: video-pipeline-audit input.mp4 output-dir nv12|p010|bgra default|software [prefix-frames:1..600]\n");return 2;}
    unsigned frameLimit=0;
    if(argc==6){
        char *end=NULL;unsigned long value=strtoul(argv[5],&end,10);
        if(!end || *end || value<1 || value>600)return 2;
        frameLimit=(unsigned)value;
    }
    if(![@[@"nv12",@"p010",@"bgra"] containsObject:@(argv[3])] ||
       ![@[@"default",@"software"] containsObject:@(argv[4])])return 2;
    NSURL *url=[NSURL fileURLWithPath:@(argv[1])];NSString *root=@(argv[2]);
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *formatName=@(argv[3]);OSType pixelFormat=[formatName isEqual:@"nv12"]?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        [formatName isEqual:@"p010"]?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_32BGRA;
    BOOL software=[@(argv[4]) isEqual:@"software"];
    NSMutableDictionary *report=[@{@"schema":@1,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"source_sha256":hashBytes([NSData dataWithContentsOfURL:url]),@"requested_format":fourcc(pixelFormat),
        @"mode":software?@"software":@"default",@"status":@"running"} mutableCopy];
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
    report[@"playable"]=@(asset.playable);
    report[@"duration_seconds"]=@(CMTimeGetSeconds(asset.duration));
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();report[@"metal_device"]=device.name?:@"none";
    if(!device){report[@"status"]=@"metal_device_missing";writeJSON(report,[root stringByAppendingPathComponent:@"result.json"]);return 1;}
    VideoAudit *audit=[VideoAudit new];audit.root=root;audit.frames=[NSMutableArray new];audit.errors=[NSMutableArray new];audit.format=pixelFormat;audit.frameLimit=frameLimit;
    audit.context=[CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates:@NO}];
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    audit.expectedFrames=(unsigned)llround(CMTimeGetSeconds(asset.duration)*track.nominalFrameRate);
    report[@"expected_frames"]=@(audit.expectedFrames);
    if(frameLimit){report[@"frame_limit"]=@(frameLimit);report[@"scope"]=@"bounded prefix; only first frame bytes saved; playback not tested";}
    NSError *error=nil;AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    [reader addOutput:output];[reader startReading];
    CMSampleBufferRef sample=[output copyNextSampleBuffer];
    unsigned skippedEdits=0;
    while(sample && (!CMSampleBufferGetFormatDescription(sample)||CMSampleBufferGetNumSamples(sample)<1)){
        skippedEdits++;CFRelease(sample);sample=[output copyNextSampleBuffer];
    }
    VTDecompressionSessionRef session=NULL;
    VTDecompressionOutputCallbackRecord callback={decoded,(__bridge void *)audit};
    NSDictionary *spec=software?@{(__bridge id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:@NO}:@{};
    OSStatus status=sample?VTDecompressionSessionCreate(NULL,CMSampleBufferGetFormatDescription(sample),(__bridge CFDictionaryRef)spec,
      (__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferPixelFormatTypeKey:@(pixelFormat),(__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{},
      (__bridge id)kCVPixelBufferMetalCompatibilityKey:@YES},&callback,&session):-1;
    report[@"session_status"]=@(status);unsigned submitted=0;double start=NSProcessInfo.processInfo.systemUptime;
    if(session) {
        CFTypeRef hardware=NULL;VTSessionCopyProperty(session,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,NULL,&hardware);
        report[@"using_hardware_decoder"]=hardware?CFBridgingRelease(hardware):NSNull.null;
        while(sample && submitted<(frameLimit?:600)) {
            CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
            if(!CMSampleBufferGetFormatDescription(sample)||CMSampleBufferGetNumSamples(sample)<1 ||
               !block || !CMBlockBufferGetDataLength(block)) {
                skippedEdits++;
            } else {
                VTDecodeInfoFlags flags=0;status=VTDecompressionSessionDecodeFrame(session,sample,0,NULL,&flags);
                if(status)[audit.errors addObject:@{@"submit_status":@(status),@"submitted":@(submitted)}];
                submitted++;
            }
            CFRelease(sample);sample=[output copyNextSampleBuffer];
        }
        VTDecompressionSessionFinishDelayedFrames(session);VTDecompressionSessionWaitForAsynchronousFrames(session);
        VTDecompressionSessionInvalidate(session);CFRelease(session);
    }
    if(sample)CFRelease(sample);
    report[@"decode_render_seconds"]=@(NSProcessInfo.processInfo.systemUptime-start);
    report[@"submitted"]=@(submitted);report[@"frames"]=audit.frames;report[@"errors"]=audit.errors;
    report[@"skipped_empty_edits"]=@(skippedEdits);
    report[@"reader_status"]=@(reader.status);report[@"reader_error"]=errorJSON(reader.error);
    [reader cancelReading];report[@"status"]=@"decoded_pixels_not_yet_compared";
    writeJSON(report,[root stringByAppendingPathComponent:@"result.json"]);
    report[@"audio"]=frameLimit?@{@"status":@"not_run_bounded_prefix"}:audioProbe(asset,root);
    fprintf(stderr,"video-audit: AVPlayer probe starting\n");
    report[@"avplayer"]=frameLimit?@{@"status":@"not_run_bounded_prefix"}:playerProbe(url);
    report[@"status"]=@"finished_pixels_not_yet_compared";
    writeJSON(report,[root stringByAppendingPathComponent:@"result.json"]);
    fprintf(stderr,"video-audit: finished %u frames\n",(unsigned)audit.frames.count);
    return 0;
} }
