#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <unistd.h>
static const int W=65,H=49;
static NSMutableArray *cases;
static NSString *directory;
static GLuint program(const char *vs,const char *fs){
 GLuint p=glCreateProgram();const char*srcs[]={vs,fs};GLenum types[]={GL_VERTEX_SHADER,GL_FRAGMENT_SHADER};
 for(int i=0;i<2;i++){GLuint s=glCreateShader(types[i]);glShaderSource(s,1,&srcs[i],NULL);glCompileShader(s);GLint ok=0;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);if(!ok){char log[4096];glGetShaderInfoLog(s,sizeof log,NULL,log);fprintf(stderr,"compile: %s\n",log);exit(2);}glAttachShader(p,s);glDeleteShader(s);}
 glBindAttribLocation(p,0,"position");glBindAttribLocation(p,1,"uv");glLinkProgram(p);GLint ok=0;glGetProgramiv(p,GL_LINK_STATUS,&ok);if(!ok){char log[4096];glGetProgramInfoLog(p,sizeof log,NULL,log);fprintf(stderr,"link: %s\n",log);exit(3);}return p;
}
static void save(NSString *name){
 glFinish();NSMutableData*d=[NSMutableData dataWithLength:W*H*4];glReadPixels(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,d.mutableBytes);GLenum error=glGetError();[d writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".rgba"]]atomically:YES];[cases addObject:@{@"name":name,@"gl_error":@(error),@"bytes":@(d.length)}];
}
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=2)return 64;alarm(90);directory=@(argv[1]);[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];cases=[NSMutableArray new];
 CGLPixelFormatAttribute a[]={kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,kCGLPFANoRecovery,kCGLPFAAllowOfflineRenderers,0};CGLPixelFormatObj pf=NULL;GLint n=0;CGLContextObj ctx=NULL;
 CGLError err=CGLChoosePixelFormat(a,&pf,&n);if(err||!pf)return 65;GLint accelerated=0;CGLDescribePixelFormat(pf,0,kCGLPFAAccelerated,&accelerated);err=CGLCreateContext(pf,NULL,&ctx);CGLReleasePixelFormat(pf);if(err||!ctx)return 66;CGLSetCurrentContext(ctx);
 GLuint target,fbo,depth;glGenTextures(1,&target);glBindTexture(GL_TEXTURE_2D,target);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,W,H,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,target,0);glGenRenderbuffers(1,&depth);glBindRenderbuffer(GL_RENDERBUFFER,depth);glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH_COMPONENT24,W,H);glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,depth);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)return 67;glViewport(0,0,W,H);glDisable(GL_DITHER);
 const char*vs="#version 150\nin vec3 position;in vec2 uv;out vec2 v;void main(){v=uv;gl_Position=vec4(position,1);}";
 GLuint textureProgram=program(vs,"#version 150\nin vec2 v;uniform sampler2D image;out vec4 color;void main(){color=texture(image,v);}");
 GLuint colorProgram=program(vs,"#version 150\nuniform vec4 tint;out vec4 color;void main(){color=tint;}");
 GLfloat quad[]={-1,-1,0,0,0, 1,-1,0,1,0, -1,1,0,0,1, 1,1,0,1,1};
 GLuint vao,vbo,ebo;glGenVertexArrays(1,&vao);glBindVertexArray(vao);glGenBuffers(1,&vbo);glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,sizeof quad,quad,GL_DYNAMIC_DRAW);glEnableVertexAttribArray(0);glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,5*sizeof(float),0);glEnableVertexAttribArray(1);glVertexAttribPointer(1,2,GL_FLOAT,GL_FALSE,5*sizeof(float),(void*)(3*sizeof(float)));glGenBuffers(1,&ebo);glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,ebo);
 uint8_t texels[13*7*4];for(int y=0;y<7;y++)for(int x=0;x<13;x++){int o=(y*13+x)*4;texels[o]=x*19;texels[o+1]=y*37;texels[o+2]=(x*13+y*29)%256;texels[o+3]=255;}
 GLuint input;glGenTextures(1,&input);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,input);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,13,7,0,GL_RGBA,GL_UNSIGNED_BYTE,texels);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
 glUseProgram(textureProgram);glUniform1i(glGetUniformLocation(textureProgram,"image"),0);glDrawArrays(GL_TRIANGLE_STRIP,0,4);save(@"texture_nearest");
 glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);GLfloat strips[]={-1,-1,0,0,0, 0,-1,0,1,0, -1,1,0,0,1, 0,1,0,1,1, 0,-1,0,0,0, 1,-1,0,1,0, 0,1,0,0,1, 1,1,0,1,1};GLushort indexes[]={0,1,2,3,65535,4,5,6,7};glBufferData(GL_ARRAY_BUFFER,sizeof strips,strips,GL_DYNAMIC_DRAW);glBufferData(GL_ELEMENT_ARRAY_BUFFER,sizeof indexes,indexes,GL_STATIC_DRAW);glEnable(GL_PRIMITIVE_RESTART);glPrimitiveRestartIndex(65535);glDrawElements(GL_TRIANGLE_STRIP,9,GL_UNSIGNED_SHORT,0);glDisable(GL_PRIMITIVE_RESTART);save(@"indexed_restart");
 glBufferData(GL_ARRAY_BUFFER,sizeof quad,quad,GL_DYNAMIC_DRAW);glUseProgram(colorProgram);GLint tint=glGetUniformLocation(colorProgram,"tint");glClearColor(0,0,1,1);glClear(GL_COLOR_BUFFER_BIT);glEnable(GL_SCISSOR_TEST);glScissor(7,5,31,23);glEnable(GL_BLEND);glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);glUniform4f(tint,1,0,0,.5);glDrawArrays(GL_TRIANGLE_STRIP,0,4);glDisable(GL_BLEND);glDisable(GL_SCISSOR_TEST);save(@"blend_scissor");
 glClearDepth(1);glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LESS);glUniform4f(tint,0,1,0,1);glDrawArrays(GL_TRIANGLE_STRIP,0,4);for(int i=0;i<4;i++)quad[i*5+2]=.5;glBufferData(GL_ARRAY_BUFFER,sizeof quad,quad,GL_DYNAMIC_DRAW);glUniform4f(tint,1,0,0,1);glDrawArrays(GL_TRIANGLE_STRIP,0,4);glDisable(GL_DEPTH_TEST);save(@"depth_reject_far");
 GLuint dest,destFbo;glGenTextures(1,&dest);glBindTexture(GL_TEXTURE_2D,dest);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,W,H,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);glGenFramebuffers(1,&destFbo);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,destFbo);glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,dest,0);glBlitFramebuffer(0,0,W,H,0,0,W,H,GL_COLOR_BUFFER_BIT,GL_NEAREST);glBindFramebuffer(GL_READ_FRAMEBUFFER,destFbo);save(@"framebuffer_blit");
 NSDictionary*r=@{@"renderer":@((const char*)glGetString(GL_RENDERER)),@"version":@((const char*)glGetString(GL_VERSION)),@"accelerated":@(accelerated),@"width":@(W),@"height":@(H),@"cases":cases};[[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil]writeToFile:[directory stringByAppendingPathComponent:@"report.json"]atomically:YES];
 glDeleteFramebuffers(1,&destFbo);glDeleteTextures(1,&dest);glDeleteTextures(1,&input);glDeleteBuffers(1,&ebo);glDeleteBuffers(1,&vbo);glDeleteVertexArrays(1,&vao);glDeleteProgram(colorProgram);glDeleteProgram(textureProgram);glDeleteRenderbuffers(1,&depth);glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&target);CGLSetCurrentContext(NULL);CGLReleaseContext(ctx);alarm(0);for(NSDictionary*c in cases)if([c[@"gl_error"]intValue])return 1;return accelerated?0:1;
}}
