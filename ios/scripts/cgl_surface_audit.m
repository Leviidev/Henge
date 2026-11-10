/* Public CGL/CAOpenGLLayer capability probe; no injection, no app-specific code.
 * Tests strict hardware selection, a software-eligible request, FBO pixels,
 * IOSurface import, and a visible layer backed by the actual software context. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLRenderers.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurfaceRef.h>

static NSMutableDictionary *report;
static NSString *reportPath;
static void save(void) {
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
      writeToFile:reportPath options:NSDataWritingAtomic error:nil];
}
static NSArray *pixel(GLint x,GLint y) {
    uint8_t p[4]={0xA5,0xA5,0xA5,0xA5};glReadPixels(x,y,1,1,GL_RGBA,GL_UNSIGNED_BYTE,p);
    return @[@(p[0]),@(p[1]),@(p[2]),@(p[3])];
}
static NSDictionary *offscreen(CGLContextObj context) {
    CGLSetCurrentContext(context);
    GLuint tex=0,fbo=0;glGenTextures(1,&tex);glBindTexture(GL_TEXTURE_2D,tex);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,4,4,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
    glViewport(0,0,4,4);glClearColor(.25,.5,.75,1);glClear(GL_COLOR_BUFFER_BIT);
    NSArray *fboPixel=pixel(1,1);GLenum fboError=glGetError(),status=glCheckFramebufferStatus(GL_FRAMEBUFFER);
    NSMutableDictionary *r=[@{@"fbo_status":@(status),@"fbo_rgba":fboPixel,@"fbo_error":@(fboError),
      @"renderer":@((const char *)glGetString(GL_RENDERER)),@"version":@((const char *)glGetString(GL_VERSION))} mutableCopy];
    IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
      (__bridge id)kIOSurfaceWidth:@16,(__bridge id)kIOSurfaceHeight:@16,(__bridge id)kIOSurfaceBytesPerRow:@64,
      (__bridge id)kIOSurfaceBytesPerElement:@4,(__bridge id)kIOSurfaceAllocSize:@1024,(__bridge id)kIOSurfacePixelFormat:@((OSType)'BGRA')});
    if(surface) {
        IOSurfaceLock(surface,0,NULL);uint8_t *bytes=IOSurfaceGetBaseAddress(surface);
        for(unsigned y=0;y<16;y++)for(unsigned x=0;x<16;x++){
            uint8_t *p=bytes+y*IOSurfaceGetBytesPerRow(surface)+x*4;p[0]=0;p[1]=128;p[2]=255;p[3]=255;
        }
        IOSurfaceUnlock(surface,0,NULL);
        GLuint rectangle=0;glGenTextures(1,&rectangle);glBindTexture(GL_TEXTURE_RECTANGLE,rectangle);
        CGLError error=CGLTexImageIOSurface2D(context,GL_TEXTURE_RECTANGLE,GL_RGBA8,16,16,GL_BGRA,GL_UNSIGNED_INT_8_8_8_8_REV,surface,0);
        r[@"iosurface_import"]=@(error);
        if(!error){
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_RECTANGLE,rectangle,0);
            r[@"iosurface_fbo_status"]=@(glCheckFramebufferStatus(GL_FRAMEBUFFER));
            r[@"iosurface_rgba"]=pixel(1,1);r[@"iosurface_gl_error"]=@(glGetError());
        }
        glDeleteTextures(1,&rectangle);CFRelease(surface);
    } else r[@"iosurface_creation_failed"]=@YES;
    glBindFramebuffer(GL_FRAMEBUFFER,0);glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&tex);
    CGLSetCurrentContext(NULL);return r;
}
static CGLContextObj context(NSString *name,CGLPixelFormatAttribute *attributes) {
    CGLPixelFormatObj format=NULL;GLint count=0;CGLContextObj ctx=NULL;
    CGLError choose=CGLChoosePixelFormat(attributes,&format,&count);
    NSMutableDictionary *row=[@{@"name":name,@"choose":@(choose),@"formats":@(count)} mutableCopy];
    if(format) {
        GLint accelerated=0;CGLDescribePixelFormat(format,0,kCGLPFAAccelerated,&accelerated);row[@"accelerated"]=@(accelerated);
        CGLError create=CGLCreateContext(format,NULL,&ctx);row[@"create"]=@(create);
        if(ctx)row[@"output"]=offscreen(ctx);
        CGLReleasePixelFormat(format);
    }
    [report[@"contexts"] addObject:row];return ctx;
}

@interface AuditLayer : CAOpenGLLayer
@property CGLContextObj context;
@property NSUInteger draws;
@end
@implementation AuditLayer
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {return CGLRetainPixelFormat(CGLGetPixelFormat(self.context));}
- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat {return CGLRetainContext(self.context);}
- (BOOL)canDrawInCGLContext:(CGLContextObj)c pixelFormat:(CGLPixelFormatObj)p forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)s {return YES;}
- (void)drawInCGLContext:(CGLContextObj)c pixelFormat:(CGLPixelFormatObj)p forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)s {
    CGLLockContext(c);CGLSetCurrentContext(c);GLint viewport[4]={0};glGetIntegerv(GL_VIEWPORT,viewport);
    GLint w=viewport[2],h=viewport[3];
    glDisable(GL_SCISSOR_TEST);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
    const GLfloat colors[4][3]={{1,0,0},{0,1,0},{0,0,1},{1,1,0}};
    glEnable(GL_SCISSOR_TEST);
    for(int i=0;i<4;i++){
        glScissor((i%2)*(w/2),(i/2)*(h/2),w/2,h/2);
        glClearColor(colors[i][0],colors[i][1],colors[i][2],1);glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    NSArray *samples=@[pixel(w/4,h/4),pixel(3*w/4,h/4),pixel(w/4,3*h/4),pixel(3*w/4,3*h/4)];
    GLenum error=glGetError();self.draws++;
    NSDictionary *result=@{@"width":@(w),@"height":@(h),@"draws":@(self.draws),@"samples":samples,@"gl_error":@(error)};
    [super drawInCGLContext:c pixelFormat:p forLayerTime:t displayTime:s];CGLUnlockContext(c);
    dispatch_async(dispatch_get_main_queue(), ^{report[@"layer"]=result;save();});
}
@end

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2)return 2;reportPath=@(argv[1]);
    report=[@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"contexts":[NSMutableArray new],@"status":@"running"} mutableCopy];
    CGLPixelFormatAttribute strict[]={kCGLPFAAllowOfflineRenderers,kCGLPFADoubleBuffer,kCGLPFAAccelerated,kCGLPFANoRecovery,
       kCGLPFAColorSize,24,kCGLPFAAlphaSize,8,kCGLPFADepthSize,24,kCGLPFASupportsAutomaticGraphicsSwitching,0};
    CGLPixelFormatAttribute eligible[]={kCGLPFAAllowOfflineRenderers,kCGLPFADoubleBuffer,kCGLPFAColorSize,24,kCGLPFAAlphaSize,8,kCGLPFADepthSize,24,0};
    CGLPixelFormatAttribute software[]={kCGLPFARendererID,kCGLRendererGenericFloatID,kCGLPFAAllowOfflineRenderers,kCGLPFADoubleBuffer,
       kCGLPFAColorSize,24,kCGLPFAAlphaSize,8,kCGLPFADepthSize,24,0};
    CGLContextObj a=context(@"hardware-only",strict),b=context(@"software-eligible",eligible),c=context(@"explicit-software",software);
    if(a)CGLReleaseContext(a);if(b)CGLReleaseContext(b);save();
    if(!c){report[@"status"]=@"software_context_failed";save();return 1;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,640,480)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"Henge CGL software layer audit";
    AuditLayer *layer=[AuditLayer layer];layer.context=c;layer.asynchronous=NO;
    window.contentView.wantsLayer=YES;window.contentView.layer=layer;
    [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    for(int i=0;i<20;i++) {
        [layer setNeedsDisplay];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.5]];
    }
    report[@"status"]=@"finished";save();[window orderOut:nil];window.contentView.layer=nil;layer.context=NULL;
    CGLReleaseContext(c);return 0;
} }
