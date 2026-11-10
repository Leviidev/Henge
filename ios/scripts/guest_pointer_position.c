/* Position the guest cursor for a subsequent real Henge input click. Does not
 * inject a click, modify permissions, or use accessibility automation. */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    double x=strtod(argv[1],NULL),y=strtod(argv[2],NULL);
    if(!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1)return 2;
    CGRect b=CGDisplayBounds(CGMainDisplayID());
    CGError err=CGWarpMouseCursorPosition(CGPointMake(b.origin.x+x*b.size.width,b.origin.y+y*b.size.height));
    printf("warp=%d bounds=%g,%g,%g,%g\n",err,b.origin.x,b.origin.y,b.size.width,b.size.height);
    return err==kCGErrorSuccess?0:1;
}
