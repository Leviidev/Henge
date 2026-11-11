"""Concurrent host reads never wait on replay and receive one consistent snapshot."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
body='''#import <Foundation/Foundation.h>
#include "pvg_render_status.h"
#include <stdatomic.h>
int main(){@autoreleasepool{HvRenderStatus*s=[HvRenderStatus new];[s setCode:0 message:@"0"];
 __block _Atomic int errors=0;
 dispatch_apply(16000,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){
   if(i%2)[s setCode:(int)(i%3) message:[NSString stringWithFormat:@"%zu",i%3]];
   else{char b[32];int code=[s copyMessage:b length:sizeof b];if(atoi(b)!=code)atomic_fetch_add(&errors,1);}
 });
 [s setCode:2 message:@"long error detail"];char b[4]={1,1,1,1};if([s copyMessage:b length:4]!=2||b[3]!=0)return 2;
 if([s copyMessage:NULL length:0]!=2)return 3;[s setCode:0 message:nil];if([s copyMessage:b length:4]!=0||b[0]!=0)return 4;
 printf("16000 concurrent status operations and bounded-copy/reset checks; errors=%d\\n",atomic_load(&errors));return atomic_load(&errors)?1:0;
}}
'''
with tempfile.TemporaryDirectory()as t:
 p=Path(t);(p/'test.m').write_text(body)
 subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-I'+str(root/'devices'),str(p/'test.m'),'-framework','Foundation','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
