/* Build for Sonoma with Foundation, AVFoundation, VideoToolbox, OpenGL. */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLRenderers.h>

static void probeGL(const char *name,CGLPixelFormatAttribute *attributes) {
    CGLPixelFormatObj pix=NULL; GLint count=0;
    CGLError e=CGLChoosePixelFormat(attributes,&pix,&count);
    printf("GL %s choose=%d %s count=%d\n",name,e,CGLErrorString(e),count);
    if(!pix)return;
    CGLContextObj ctx=NULL;e=CGLCreateContext(pix,NULL,&ctx);
    printf("GL %s create=%d %s\n",name,e,CGLErrorString(e));
    if(ctx) {
        CGLSetCurrentContext(ctx);
        printf("GL %s renderer=%s version=%s\n",name,glGetString(GL_RENDERER),glGetString(GL_VERSION));
        if(((const char *)glGetString(GL_VERSION))[0]>='3') {
            GLuint tex,fb;glGenTextures(1,&tex);glBindTexture(GL_TEXTURE_2D,tex);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,4,4,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
            glGenFramebuffers(1,&fb);glBindFramebuffer(GL_FRAMEBUFFER,fb);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
            unsigned char p[4]={0};glViewport(0,0,4,4);glClearColor(0.25,0.5,0.75,1);glClear(GL_COLOR_BUFFER_BIT);
            glReadPixels(0,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,p);
            printf("GL %s framebuffer=%x read=%u,%u,%u,%u error=%x\n",name,glCheckFramebufferStatus(GL_FRAMEBUFFER),p[0],p[1],p[2],p[3],glGetError());
            glDeleteFramebuffers(1,&fb);glDeleteTextures(1,&tex);
        }
        CGLSetCurrentContext(NULL);CGLDestroyContext(ctx);
    }
    CGLDestroyPixelFormat(pix);
}
static void output(void *ref,void *source,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime pts,CMTime duration) {
    int *received=ref;
    if(image)(*received)++;
    printf("VT callback status=%d image=%dx%d flags=%u\n",status,image?(int)CVPixelBufferGetWidth(image):0,image?(int)CVPixelBufferGetHeight(image):0,flags);
}
int main(int argc,const char **argv) { @autoreleasepool {
    printf("OS %s\n",NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
    CGLRendererInfoObj info=NULL;GLint count=0;CGLError er=CGLQueryRendererInfo(~0u,&info,&count);
    printf("GL renderer query=%d count=%d\n",er,count);
    for(GLint i=0;i<count;i++){GLint id=0,accelerated=0,online=0;CGLDescribeRenderer(info,i,kCGLRPRendererID,&id);CGLDescribeRenderer(info,i,kCGLRPAccelerated,&accelerated);CGLDescribeRenderer(info,i,kCGLRPOnline,&online);printf("GL renderer id=%x accelerated=%d online=%d\n",id,accelerated,online);}
    if(info)CGLDestroyRendererInfo(info);
    CGLPixelFormatAttribute minimal[]={0};
    CGLPixelFormatAttribute accelerated[]={kCGLPFAAccelerated,kCGLPFAAllowOfflineRenderers,0};
    CGLPixelFormatAttribute core[]={kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAllowOfflineRenderers,0};
    CGLPixelFormatAttribute software[]={kCGLPFARendererID,(CGLPixelFormatAttribute)kCGLRendererGenericFloatID,kCGLPFAAllowOfflineRenderers,0};
    CGLPixelFormatAttribute softwareCore[]={kCGLPFARendererID,(CGLPixelFormatAttribute)kCGLRendererGenericFloatID,kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAllowOfflineRenderers,0};
    probeGL("minimal",minimal);probeGL("accelerated",accelerated);probeGL("core",core);probeGL("software",software);probeGL("software-core",softwareCore);
    OSStatus status=0;
    printf("VT hardware decode h264=%d hevc=%d\n",VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC));
    for(int i=1;i<argc;i++) {
        NSURL *url=[NSURL fileURLWithPath:@(argv[i])];
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        printf("ASSET %s playable=%d track=%s\n",url.lastPathComponent.UTF8String,asset.playable,track?"yes":"no");
        if(!track)continue;
        for(int mode=0;mode<2;mode++) {
            NSError *err=nil;
            AVAssetReader *reader=[[AVAssetReader alloc]initWithAsset:asset error:&err];
            AVAssetReaderTrackOutput *out=[[AVAssetReaderTrackOutput alloc]initWithTrack:track outputSettings:nil];
            [reader addOutput:out];[reader startReading];
            CMSampleBufferRef sample=[out copyNextSampleBuffer];
            while(sample && (!CMSampleBufferGetFormatDescription(sample)||CMSampleBufferGetNumSamples(sample)<1)) {
                printf("ASSET skipping empty edit sample\n");CFRelease(sample);sample=[out copyNextSampleBuffer];
            }
            if(!sample){printf("ASSET read failure %s\n",reader.error.description.UTF8String);continue;}
            CMVideoFormatDescriptionRef format=CMSampleBufferGetFormatDescription(sample);
            FourCharCode sub=CMFormatDescriptionGetMediaSubType(format);
            printf("FORMAT subtype=%c%c%c%c %s\n",(sub>>24)&255,(sub>>16)&255,(sub>>8)&255,sub&255,[(__bridge id)format description].UTF8String);
            NSDictionary *spec=mode?@{(__bridge id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:@NO}:@{};
            VTDecompressionSessionRef session=NULL;int received=0;
            VTDecompressionOutputCallbackRecord callback={output,&received};
            status=VTDecompressionSessionCreate(NULL,format,(__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)},&callback,&session);
            printf("VT %s mode=%s create=%d\n",url.lastPathComponent.UTF8String,mode?"software":"default",status);
            if(session) {
                for(int n=0;n<8&&sample;n++) {
                    VTDecodeInfoFlags flags=0;
                    status=VTDecompressionSessionDecodeFrame(session,sample,0,NULL,&flags);
                    printf("VT decode=%d flags=%u\n",status,flags);
                    CFRelease(sample);sample=[out copyNextSampleBuffer];
                }
                VTDecompressionSessionFinishDelayedFrames(session);VTDecompressionSessionWaitForAsynchronousFrames(session);
                printf("VT %s mode=%d received=%d\n",url.lastPathComponent.UTF8String,mode,received);
                VTDecompressionSessionInvalidate(session);CFRelease(session);
            }
            if(sample)CFRelease(sample);
            [reader cancelReading];
        }
    }
    fflush(stdout);
}return 0;}
