/* Pure state/semantic test: fake encoder records calls; no GPU API executes. */
#import "pvg_viewport_replay.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

@interface ViewportRecorder : NSObject
@property(nonatomic) NSData *values;
@property(nonatomic) BOOL array;
@property(nonatomic) NSUInteger calls;
- (void)setViewport:(MTLViewport)viewport;
- (void)setViewports:(const MTLViewport *)viewports count:(NSUInteger)count;
@end
@implementation ViewportRecorder
- (void)setViewport:(MTLViewport)viewport {
    self.values = [NSData dataWithBytes:&viewport length:sizeof viewport]; self.array = NO; self.calls++;
}
- (void)setViewports:(const MTLViewport *)viewports count:(NSUInteger)count {
    self.values = [NSData dataWithBytes:viewports length:count * sizeof(*viewports)]; self.array = YES; self.calls++;
}
@end
static unsigned checks;
static void check(BOOL ok, const char *name) {
    checks++;
    if (!ok) { fprintf(stderr,"FAIL %s\n",name); exit(1); }
}
static MTLViewport at(ViewportRecorder *recorder, NSUInteger index) {
    MTLViewport value;
    memcpy(&value,(const char *)recorder.values.bytes + index * sizeof value,sizeof value);
    return value;
}
static BOOL closeEnough(double a, double b) { return fabs(a-b) <= 1e-12; }
int main(void) { @autoreleasepool {
    HvPvgViewportReplay *state = [HvPvgViewportReplay new];
    ViewportRecorder *record = [ViewportRecorder new];
    id<MTLRenderCommandEncoder> encoder = (id)record;
    NSObject *normal = [NSObject new], *converted = [NSObject new];
    hv_pvg_pipeline_set_gl_clip(converted, YES);
    check(!hv_pvg_pipeline_gl_clip(normal) && !hv_pvg_pipeline_gl_clip(nil), "unmarked/nil pipeline stays native");
    check(!hv_pvg_viewport_pipeline(state,encoder,converted) && record.calls==0, "no synthetic viewport for unknown state");
    MTLViewport raw = {13.25,7.5,123.0,57.0,.5,1};
    check(hv_pvg_viewport_record(state,encoder,&raw,1,NO), "single viewport accepted");
    MTLViewport out = at(record,0);
    check(out.znear==0 && out.zfar==1 && !memcmp(&out,&raw,4*sizeof(double)), "single mapped near only");
    check(!memcmp(state->raw.bytes,&raw,sizeof raw), "raw input is preserved");
    hv_pvg_viewport_pipeline(state,encoder,converted);
    out=at(record,0);
    check(out.znear==0 && out.zfar==1,"repeated converted pipeline does not accumulate");
    hv_pvg_viewport_pipeline(state,encoder,normal);
    check(!memcmp(record.values.bytes,&raw,sizeof raw), "switch to ordinary pipeline restores exact raw bytes");
    hv_pvg_viewport_pipeline(state,encoder,converted);
    out=at(record,0);
    check(out.znear==0,"switch back reapplies from raw");
    MTLViewport arrays[]={{1,2,64,32,.5,.2},{5,6,21,19,.5,.8},{8,9,9,10,.4,.4}};
    NSData *saved=[NSData dataWithBytes:arrays length:sizeof arrays];
    hv_pvg_viewport_record(state,encoder,arrays,3,YES);
    check(record.array && record.values.length==sizeof arrays,"array setter/count preserved");
    for (NSUInteger i=0;i<3;i++) {
        out=at(record,i);
        check(!memcmp(&out,&arrays[i],4*sizeof(double)) && out.zfar==arrays[i].zfar && closeEnough(out.znear,2*arrays[i].znear-arrays[i].zfar),"array geometry/far preserved, reversed and equal ranges handled");
    }
    arrays[0].znear=.123; /* caller's temporary storage can change */
    check([state->raw isEqual:saved],"record owns raw byte copy");
    hv_pvg_viewport_pipeline(state,encoder,normal);
    check([record.values isEqual:saved] && record.array,"ordinary pipeline restores exact array");
    hv_pvg_viewport_record(state,encoder,&raw,1,NO);
    check(!record.array && record.values.length==sizeof raw,"single command replaces prior array");
    NSUInteger before=record.calls;
    hv_pvg_viewport_reset(state);
    check(!state->raw && !state->gl_clip && !state->array,"encoder reset clears profile and viewport state");
    check(!hv_pvg_viewport_pipeline(state,encoder,converted) && record.calls==before,"new encoder cannot replay previous viewport");
    hv_pvg_viewport_pipeline(state,encoder,normal);
    hv_pvg_viewport_record(state,encoder,&raw,1,NO);
    check([record.values isEqual:[NSData dataWithBytes:&raw length:sizeof raw]],"native viewport before or after pipeline unchanged");
    /* Homogeneous clip transform + viewport contract, using legal public GL
       depth ranges, including reversed/equal ranges and non-unit positive w. */
    const double ranges[][2]={{0,1},{.2,.8},{.8,.2},{.4,.4}};
    const double ratios[]={-1,-.5,0,.5,1};
    const double ws[]={.5,1,2,4};
    for (unsigned r=0;r<4;r++) for(unsigned wi=0;wi<4;wi++) for(unsigned zi=0;zi<5;zi++) {
        double n=ranges[r][0],f=ranges[r][1],w=ws[wi],z=ratios[zi]*w;
        MTLViewport v={0,0,64,64,(n+f)/2,f};
        hv_pvg_viewport_pipeline(state,encoder,converted);
        hv_pvg_viewport_record(state,encoder,&v,1,NO);
        out=at(record,0);
        double shaderZ=.5*(z+w)/w;
        double metalDepth=out.znear+(out.zfar-out.znear)*shaderZ;
        double glDepth=(n+f)/2+(f-n)/2*(z/w);
        check(closeEnough(metalDepth,glDepth),"paired mapping matches GL depth for nonunit w and reversed range");
    }
    const double clipRatios[]={-1.25,-1,-.5,0,.5,1,1.25};
    for(unsigned wi=0;wi<4;wi++) for(unsigned zi=0;zi<7;zi++) {
        double w=ws[wi],z=clipRatios[zi]*w,zp=.5*(z+w);
        check((z>=-w && z<=w)==(zp>=0 && zp<=w),"homogeneous near/far clip membership agrees");
    }
    printf("%u viewport state/math checks passed; no GPU calls\n", checks);
} return 0; }
