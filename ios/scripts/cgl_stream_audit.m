/* Streaming OpenGL textures through CAOpenGLLayer, with a CPU pixel oracle.
 * Explicit software CGL matches the renderer available in the guest. Checks
 * RGBA uploads and three-plane YUV shader conversion independently of VLC. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <OpenGL/CGLRenderers.h>

static NSMutableDictionary *report;
static NSString *reportPath;
static void save(void) {
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
      writeToFile:reportPath options:NSDataWritingAtomic error:nil];
}
static GLuint shader(GLenum kind, const char *source) {
    GLuint s=glCreateShader(kind); glShaderSource(s,1,&source,NULL); glCompileShader(s);
    GLint ok=0;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if(!ok){char log[2048]={0};glGetShaderInfoLog(s,sizeof(log),NULL,log);fprintf(stderr,"shader: %s\n",log);glDeleteShader(s);return 0;}
    return s;
}
static GLuint program(BOOL yuv) {
    const char *vs="#version 120\nvarying vec2 uv; void main(){gl_Position=gl_Vertex;uv=gl_MultiTexCoord0.xy;}";
    const char *fs=yuv ? "#version 120\nvarying vec2 uv;uniform sampler2D ytex,utex,vtex;void main(){float y=texture2D(ytex,uv).r-16.0/255.0;float u=texture2D(utex,uv).r-128.0/255.0;float v=texture2D(vtex,uv).r-128.0/255.0;gl_FragColor=vec4(1.164*y+1.596*v,1.164*y-.391*u-.813*v,1.164*y+2.018*u,1.0);}"
      : "#version 120\nvarying vec2 uv;uniform sampler2D ytex;void main(){gl_FragColor=texture2D(ytex,uv);}";
    GLuint v=shader(GL_VERTEX_SHADER,vs),f=shader(GL_FRAGMENT_SHADER,fs);
    if(!v||!f)return 0;
    GLuint p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);glDeleteShader(v);glDeleteShader(f);
    GLint ok=0;glGetProgramiv(p,GL_LINK_STATUS,&ok);if(!ok){glDeleteProgram(p);return 0;}
    glUseProgram(p);glUniform1i(glGetUniformLocation(p,"ytex"),0);
    if(yuv){glUniform1i(glGetUniformLocation(p,"utex"),1);glUniform1i(glGetUniformLocation(p,"vtex"),2);}
    return p;
}
static uint8_t pattern(unsigned x,unsigned y,unsigned frame,unsigned channel) {
    return (uint8_t)(16+((x/16*13+y/16*29+frame*7+channel*53)%220));
}
static int channel(float v){return (int)lrintf(fminf(255,fmaxf(0,v)));}
@interface StreamLayer : CAOpenGLLayer
@property CGLContextObj context;
@property NSUInteger frameOrdinal;
@property BOOL yuv;
@property GLuint pipeline;
@property NSUInteger failures;
@end
@implementation StreamLayer
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)m{return CGLRetainPixelFormat(CGLGetPixelFormat(self.context));}
- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)p{return CGLRetainContext(self.context);}
- (BOOL)canDrawInCGLContext:(CGLContextObj)c pixelFormat:(CGLPixelFormatObj)p forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)s{return YES;}
- (void)drawInCGLContext:(CGLContextObj)c pixelFormat:(CGLPixelFormatObj)p forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)s {
    CGLLockContext(c);CGLSetCurrentContext(c);
    GLint vp[4];glGetIntegerv(GL_VIEWPORT,vp);NSUInteger w=vp[2],h=vp[3];
    if(!w||!h||w>4096||h>4096){CGLUnlockContext(c);return;}
    if(!self.pipeline)self.pipeline=program(self.yuv);
    if(!self.pipeline){self.failures++;CGLUnlockContext(c);return;}
    glUseProgram(self.pipeline);glDisable(GL_BLEND);glDisable(GL_DITHER);glDisable(GL_SCISSOR_TEST);glDisable(GL_DEPTH_TEST);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);glPixelStorei(GL_PACK_ALIGNMENT,1);
    GLuint textures[3]={0};glGenTextures(self.yuv?3:1,textures);
    unsigned frame=(unsigned)self.frameOrdinal;
    for(unsigned plane=0;plane<(self.yuv?3u:1u);plane++){
        NSUInteger pw=plane?w/2:w,ph=plane?h/2:h,bpp=self.yuv?1:4;
        NSMutableData *data=[NSMutableData dataWithLength:pw*ph*bpp];uint8_t *bytes=data.mutableBytes;
        for(NSUInteger y=0;y<ph;y++)for(NSUInteger x=0;x<pw;x++){
            if(self.yuv)bytes[y*pw+x]=pattern((unsigned)x,(unsigned)y,frame,plane);
            else {for(unsigned k=0;k<3;k++)bytes[(y*pw+x)*4+k]=pattern((unsigned)x,(unsigned)y,frame,k);bytes[(y*pw+x)*4+3]=255;}
        }
        glActiveTexture(GL_TEXTURE0+plane);glBindTexture(GL_TEXTURE_2D,textures[plane]);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D,0,self.yuv?GL_LUMINANCE8:GL_RGBA8,(GLsizei)pw,(GLsizei)ph,0,self.yuv?GL_LUMINANCE:GL_RGBA,GL_UNSIGNED_BYTE,data.bytes);
    }
    glActiveTexture(GL_TEXTURE0);
    glBegin(GL_TRIANGLE_STRIP);
    glTexCoord2f(0,0);glVertex2f(-1,-1);glTexCoord2f(1,0);glVertex2f(1,-1);
    glTexCoord2f(0,1);glVertex2f(-1,1);glTexCoord2f(1,1);glVertex2f(1,1);glEnd();
    NSMutableData *output=[NSMutableData dataWithLength:w*h*4];glReadPixels(vp[0],vp[1],(GLsizei)w,(GLsizei)h,GL_RGBA,GL_UNSIGNED_BYTE,output.mutableBytes);
    GLenum error=glGetError();const uint8_t *actual=output.bytes;NSUInteger bad=0;int maximum=0;
    for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++){
        int expected[4]={0,0,0,255};
        if(self.yuv){float yy=pattern(x,y,frame,0)-16,uu=pattern(x/2,y/2,frame,1)-128,vv=pattern(x/2,y/2,frame,2)-128;
          expected[0]=channel(1.164f*yy+1.596f*vv);expected[1]=channel(1.164f*yy-.391f*uu-.813f*vv);expected[2]=channel(1.164f*yy+2.018f*uu);
        }else for(unsigned k=0;k<3;k++)expected[k]=pattern(x,y,frame,k);
        for(unsigned k=0;k<4;k++){int delta=abs((int)actual[(y*w+x)*4+k]-expected[k]);maximum=MAX(maximum,delta);bad+=delta>(self.yuv?2:0);}
    }
    BOOL ok=!bad&&!error;self.failures+=!ok;
    [report[@"frames"] addObject:@{@"frame":@(frame),@"yuv":@(self.yuv),@"width":@(w),@"height":@(h),@"bad_channels":@(bad),@"max_delta":@(maximum),@"gl_error":@(error),@"passed":@(ok)}];
    self.frameOrdinal++;[super drawInCGLContext:c pixelFormat:p forLayerTime:t displayTime:s];
    glDeleteTextures(self.yuv?3:1,textures);CGLUnlockContext(c);save();
}
@end
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;reportPath=@(argv[1]);
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    report=[@{@"frames":[NSMutableArray new],@"status":@"running",@"os":NSProcessInfo.processInfo.operatingSystemVersionString} mutableCopy];
    CGLPixelFormatAttribute attrs[]={kCGLPFARendererID,kCGLRendererGenericFloatID,kCGLPFAAllowOfflineRenderers,kCGLPFADoubleBuffer,kCGLPFAColorSize,24,kCGLPFAAlphaSize,8,0};
    CGLPixelFormatObj format=NULL;GLint count=0;CGLContextObj context=NULL;
    if(CGLChoosePixelFormat(attrs,&format,&count)||CGLCreateContext(format,NULL,&context)){report[@"status"]=@"context_failed";save();return 3;}
    CGLReleasePixelFormat(format);CGLSetCurrentContext(context);report[@"renderer"]=@((const char *)glGetString(GL_RENDERER));
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(70,70,640,360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    StreamLayer *layer=[StreamLayer layer];layer.context=context;layer.asynchronous=NO;
    window.contentView.wantsLayer=YES;window.contentView.layer=layer;[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    for(unsigned phase=0;phase<2;phase++){
        layer.yuv=phase;CGLSetCurrentContext(context);if(layer.pipeline)glDeleteProgram(layer.pipeline);layer.pipeline=0;
        window.title=phase?@"Henge CGL stream: YUV shader":@"Henge CGL stream: RGBA upload";
        for(unsigned i=0;i<60;i++){[layer setNeedsDisplay];[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];}
    }
    report[@"status"]=@"finished";report[@"failed_frames"]=@(layer.failures);report[@"passed"]=@(!layer.failures&&layer.frameOrdinal>=120);save();
    [window orderOut:nil];window.contentView.layer=nil;CGLSetCurrentContext(context);if(layer.pipeline)glDeleteProgram(layer.pipeline);layer.context=NULL;CGLSetCurrentContext(NULL);CGLReleaseContext(context);
    return [report[@"passed"] boolValue]?0:1;
}}
