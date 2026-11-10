/* Strict accelerated CGL discovery and clear/readback; no software fallback. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <mach-o/dyld.h>
#include <unistd.h>

static NSString *output;
static NSMutableDictionary *report;
static void save(NSString *phase) {
    report[@"phase"]=phase;
    NSData *d=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:output options:NSDataWritingAtomic error:nil];
}
static NSString *string(const GLubyte *p) { return p?@((const char *)p):@""; }
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2)return 64; alarm(45); output=@(argv[1]);
    report=[@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"discovery_override":@(getenv("HENGE_CGL_DISCOVERY_TEST") && !strcmp(getenv("HENGE_CGL_DISCOVERY_TEST"),"1"))}mutableCopy]; save(@"start");
    NSMutableArray *devices=[NSMutableArray new];
    for(id<MTLDevice> d in MTLCopyAllDevices()) [devices addObject:@{@"name":d.name,@"registry_id":@(d.registryID)}];
    report[@"metal_devices"]=devices; save(@"before_renderer_enumeration");
    CGLRendererInfoObj info=NULL; GLint count=0;
    CGLError error=CGLQueryRendererInfo(0xffffffff,&info,&count);
    report[@"renderer_query_error"]=@(error); NSMutableArray *renderers=[NSMutableArray new];
    if(info) { for(GLint i=0;i<count;i++) { GLint rid=0,acc=0,online=0; CGLDescribeRenderer(info,i,kCGLRPRendererID,&rid); CGLDescribeRenderer(info,i,kCGLRPAccelerated,&acc); CGLDescribeRenderer(info,i,kCGLRPOnline,&online); [renderers addObject:@{@"id":@(rid),@"accelerated":@(acc),@"online":@(online)}]; } CGLDestroyRendererInfo(info); }
    report[@"renderers"]=renderers; save(@"before_strict_pixel_format");
    CGLPixelFormatAttribute attrs[]={kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,kCGLPFANoRecovery,kCGLPFAAllowOfflineRenderers,kCGLPFAColorSize,(CGLPixelFormatAttribute)24,kCGLPFAAlphaSize,(CGLPixelFormatAttribute)8,(CGLPixelFormatAttribute)0};
    CGLPixelFormatObj pf=NULL; CGLContextObj ctx=NULL; GLint formats=0;
    error=CGLChoosePixelFormat(attrs,&pf,&formats); report[@"choose_error"]=@(error);report[@"formats"]=@(formats);
    if(pf) { GLint accelerated=0;CGLDescribePixelFormat(pf,0,kCGLPFAAccelerated,&accelerated);report[@"accelerated"]=@(accelerated);save(@"before_create_context");error=CGLCreateContext(pf,NULL,&ctx);report[@"create_error"]=@(error);CGLReleasePixelFormat(pf); }
    report[@"context_created"]=@(ctx!=NULL);save(@"context_result");
    if(ctx) {
        CGLSetCurrentContext(ctx);report[@"gl_renderer"]=string(glGetString(GL_RENDERER));report[@"gl_vendor"]=string(glGetString(GL_VENDOR));report[@"gl_version"]=string(glGetString(GL_VERSION));save(@"before_clear");
        GLuint tex=0,fbo=0;glGenTextures(1,&tex);glBindTexture(GL_TEXTURE_2D,tex);uint8_t seed[64]; for(int i=0;i<16;i++){seed[i*4]=17;seed[i*4+1]=34;seed[i*4+2]=51;seed[i*4+3]=255;} glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,4,4,0,GL_RGBA,GL_UNSIGNED_BYTE,seed);glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);report[@"fbo_status"]=@(glCheckFramebufferStatus(GL_FRAMEBUFFER));glViewport(0,0,4,4); uint8_t seeded[4]={0}; glReadPixels(1,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,seeded); report[@"seed_rgba"]=@[@(seeded[0]),@(seeded[1]),@(seeded[2]),@(seeded[3])]; save(@"seed_readback"); glClearColor(.25,.5,.75,1);glClear(GL_COLOR_BUFFER_BIT);glFinish();uint8_t pixel[4]={0};glReadPixels(1,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);report[@"clear_rgba"]=@[@(pixel[0]),@(pixel[1]),@(pixel[2]),@(pixel[3])];report[@"gl_error"]=@(glGetError());
        uint8_t texels[64]={0}; glGetTexImage(GL_TEXTURE_2D,0,GL_RGBA,GL_UNSIGNED_BYTE,texels);
        report[@"clear_get_tex_image"]=@[@(texels[20]),@(texels[21]),@(texels[22]),@(texels[23])];
        save(@"before_glsl");
        const char *vs="#version 150\nin vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}";
        const char *fs="#version 150\nout vec4 color; void main(){color=vec4(1.0,0.0,0.0,1.0);}";
        GLuint vert=glCreateShader(GL_VERTEX_SHADER),frag=glCreateShader(GL_FRAGMENT_SHADER);
        glShaderSource(vert,1,&vs,NULL);glCompileShader(vert); glShaderSource(frag,1,&fs,NULL);glCompileShader(frag);
        GLint vok=0,fok=0,linked=0;GLchar log[4096]={0}; glGetShaderiv(vert,GL_COMPILE_STATUS,&vok);glGetShaderInfoLog(vert,sizeof(log),NULL,log); report[@"vertex_compile"]=@(vok);report[@"vertex_log"]=@((const char *)log);
        log[0]=0;glGetShaderiv(frag,GL_COMPILE_STATUS,&fok);glGetShaderInfoLog(frag,sizeof(log),NULL,log);report[@"fragment_compile"]=@(fok);report[@"fragment_log"]=@((const char *)log);save(@"compiled_glsl");
        GLuint program=glCreateProgram();glAttachShader(program,vert);glAttachShader(program,frag);glBindAttribLocation(program,0,"position");glLinkProgram(program);glGetProgramiv(program,GL_LINK_STATUS,&linked);log[0]=0;glGetProgramInfoLog(program,sizeof(log),NULL,log);report[@"program_linked"]=@(linked);report[@"program_log"]=@((const char *)log);save(@"before_triangle");
        if(vok && fok && linked){
            GLuint vao=0,vbo=0;GLfloat vertices[]={-1,-1,3,-1,-1,3};glGenVertexArrays(1,&vao);glBindVertexArray(vao);glGenBuffers(1,&vbo);glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_STATIC_DRAW);glEnableVertexAttribArray(0);glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,0);glUseProgram(program);glDrawArrays(GL_TRIANGLES,0,3);glFinish();uint8_t px[4]={165,165,165,165};glReadPixels(1,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,px);report[@"triangle_rgba"]=@[@(px[0]),@(px[1]),@(px[2]),@(px[3])];report[@"triangle_error"]=@(glGetError());glDeleteBuffers(1,&vbo);glDeleteVertexArrays(1,&vao);
        }
        glDeleteProgram(program);glDeleteShader(vert);glDeleteShader(frag);
glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&tex);CGLSetCurrentContext(NULL);CGLReleaseContext(ctx);
    }
    NSMutableArray *images=[NSMutableArray new];for(uint32_t i=0;i<_dyld_image_count();i++){NSString*n=@(_dyld_get_image_name(i));if([n containsString:@"OpenGL"]||[n containsString:@"GLEngine"]||[n containsString:@"registry-discovery"])[images addObject:n];}report[@"loaded_gl_images"]=images;save(@"finished");alarm(0);return 0;
} }
