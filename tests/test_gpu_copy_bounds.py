"""Execute the production copy-range arithmetic under sanitizers."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=r'''
#include "gpu_copy_bounds.h"
#include <assert.h>
int main(void) {
 uint64_t at=0,image=0;
 assert(hv_gpu_copy_range(0,0,0,256,256,4,1,1,65536,&at,&image)&&at==256&&image==1024);
 assert(hv_gpu_copy_range(1024,4096,2,32,128,7,2,4,65536,&at,&image)&&at==9248&&image==256);
 assert(!hv_gpu_copy_range(0,UINT64_MAX,2,0,256,4,1,1,65536,&at,&image));
 assert(!hv_gpu_copy_range(65535,0,0,2,1,1,1,1,65536,&at,&image));
 assert(!hv_gpu_copy_range(0,0,0,0,UINT64_MAX,2,1,1,UINT64_MAX,&at,&image));
 assert(!hv_gpu_copy_range(0,0,0,0,256,4,UINT32_MAX,1,65536,&at,&image));
 assert(!hv_gpu_copy_range(0,0,0,0,256,0,1,1,65536,&at,&image));
 assert(!hv_gpu_copy_range(0,0,0,0,0,4,1,1,65536,&at,&image));
 for(unsigned h=1;h<256;h++)for(unsigned d=1;d<16;d++) {
  int ok=hv_gpu_copy_range(3,17,5,7,63,h,d,4,65536,&at,&image);
  if(ok)assert(at<=65536&&image>0&&d<=(65536-at)/image);
 }
 return 0;
}'''
with tempfile.TemporaryDirectory() as tmp:
 c=Path(tmp)/'bounds.c';c.write_text(s);exe=Path(tmp)/'bounds'
 subprocess.run(['cc','-O1','-g','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-I'+str(root/'devices'),str(c),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
print('GPU copy bounds: complete ranges, empty copies, overflow and mip extents passed ASan/UBSan')
