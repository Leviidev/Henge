#import <Foundation/Foundation.h>
#import "../ondevice-shaders/HGOnDeviceDynamicService.h"
#include "../../host/share.h"
#include <stdio.h>
#include <unistd.h>
#include <string.h>

static int service(const char *method,const char *path,const void *body,size_t n,void **out,size_t *length) {
    if(!strcmp(method,"POST")) { puts("request entered"); fflush(stdout); }
    return HGOnDeviceDynamicService(method,path,body,n,out,length);
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc<3||argc>4)return 64;
    if(argc==4) {
        dispatch_semaphore_t release=dispatch_semaphore_create(0);
        dispatch_async(HGOnDeviceCompilerQueue(),^{dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);});
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            if(getchar()=='r')dispatch_semaphore_signal(release);
        });
    }
    hv_share_set_shader_service(service);
    if(hv_share_start(argv[1],argv[2],nullptr))return 1;
    puts("ready"); fflush(stdout);
    for(;;)pause();
}}
