"""Run production Metal display-link arming/callbacks with controlled queues.
The macOS fixture supplies UIKit visibility and a display-link stand-in; queue
ordering, generation checks, coalescing and production pacing are exercised.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root/'devices/pvg_metal.m').read_text()
start = source.index('- (void)requestDisplayPulse {')
end = source.index('\n#endif', start)
methods = source[start:end]
fixture = r'''
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <assert.h>
#include <math.h>
#include "frame_pacing.h"
static NSMutableArray *presenterTasks, *mainTasks;
static dispatch_queue_t presenterQueue;
static void enqueue(dispatch_queue_t queue, dispatch_block_t task) {
    [(queue == presenterQueue ? presenterTasks : mainTasks) addObject:[task copy]];
}
static void drainOne(NSMutableArray *tasks) {
    assert(tasks.count); dispatch_block_t task = tasks.firstObject;
    [tasks removeObjectAtIndex:0]; task();
}
@interface TestScene : NSObject
@property NSInteger activationState;
@end
@implementation TestScene @end
@interface TestScreen : NSObject
@property NSInteger maximumFramesPerSecond;
@end
@implementation TestScreen @end
@interface TestWindow : NSObject
@property (nonatomic, strong) TestScene *windowScene;
@property (nonatomic, strong) TestScreen *screen;
@end
@implementation TestWindow @end
@interface TestView : NSObject
@property (nonatomic, strong) TestWindow *window;
@property BOOL hidden;
@property double alpha;
@end
@implementation TestView @end
@class HvReplay;
@interface HvDisplayPulse : NSObject
@property (weak) HvReplay *owner;
@end
@implementation HvDisplayPulse @end
@interface TestLink : NSObject
@property BOOL paused, invalidated;
@property (weak) HvDisplayPulse *delegate;
@property CAFrameRateRange preferredFrameRateRange;
- (instancetype)initWithMetalLayer:(CAMetalLayer *)layer;
- (void)addToRunLoop:(NSRunLoop *)runLoop forMode:(NSString *)mode;
- (void)invalidate;
@end
@implementation TestLink
- (instancetype)initWithMetalLayer:(CAMetalLayer *)layer { (void)layer; return [super init]; }
- (void)addToRunLoop:(NSRunLoop *)runLoop forMode:(NSString *)mode { (void)runLoop;(void)mode; }
- (void)invalidate { self.invalidated=YES; self.paused=YES; }
@end
@interface TestUpdate : NSObject
@property (nonatomic, strong) id drawable;
@end
@implementation TestUpdate @end
@interface HvReplay : NSObject {
@public
    os_unfair_lock screen_lock;
    atomic_int stopping;
    _Atomic unsigned presentation_inflight;
    _Atomic uint64_t presentation_backpressure;
    BOOL display_arm_pending, display_quiesced, display_scene_active, screen_dirty;
    BOOL display_pulse_active,presenter_running;
    uint32_t display_prepared_w,display_prepared_h;
    uint64_t layer_generation, display_link_generation;
    uint32_t screen_w, screen_h;
    BOOL desktop_fx;
    dispatch_queue_t presenter;
    CAMetalLayer *layer;
    __weak CAMetalLayer *display_link_layer;
    TestLink *display_link;
    id display_delegate, display_drawable;
    int pacing_fps, presents, preflights;
    HvFramePacing frame_pacing;
}
- (CGSize)presentationSizeForWidth:(uint32_t)width height:(uint32_t)height;
- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target;
- (void)updatePacingPolicy;
- (void)kickPresenter:(BOOL)fresh;
- (void)requestDisplayPulse;
- (void)displayPulse:(TestLink *)link update:(TestUpdate *)update;
@end
#define UIView TestView
#define UIWindowScene TestScene
#define UISceneActivationStateForegroundActive 0
#define CAMetalDisplayLink TestLink
#define CAMetalDisplayLinkUpdate TestUpdate
#define dispatch_async enqueue
@implementation HvReplay
- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target { (void)target; preflights++; return YES; }
- (void)updatePacingPolicy {}
- (CGSize)presentationSizeForWidth:(uint32_t)width height:(uint32_t)height {
    return CGSizeMake(width*(desktop_fx?2:1),height*(desktop_fx?2:1));
}
- (void)kickPresenter:(BOOL)fresh { (void)fresh; assert(display_drawable); presents++; screen_dirty=NO; }
METHODS
@end
static void request(HvReplay *r) {
    os_unfair_lock_lock(&r->screen_lock); [r requestDisplayPulse]; os_unfair_lock_unlock(&r->screen_lock);
}
int main(void) { @autoreleasepool {
    presenterTasks=[NSMutableArray new]; mainTasks=[NSMutableArray new];
    presenterQueue=dispatch_queue_create("test.presenter",NULL);
    TestView *view=[TestView new]; view.alpha=1;
    view.window=[TestWindow new];view.window.windowScene=[TestScene new];
    view.window.screen=[TestScreen new];view.window.screen.maximumFramesPerSecond=120;
    HvReplay *r=[HvReplay new];r->screen_lock=(os_unfair_lock)OS_UNFAIR_LOCK_INIT;r->presenter=presenterQueue;
    r->display_scene_active=YES;r->screen_dirty=YES;r->screen_w=2752;r->screen_h=2064;
    r->layer=[CAMetalLayer layer];r->layer.delegate=(id)view;r->layer_generation=1;
    for(int i=0;i<100;++i)request(r);
    assert(presenterTasks.count==1);drainOne(presenterTasks);
    assert(mainTasks.count==1 && r->preflights==1);
    // A newer target gets its own arm while the old main task is queued.
    CAMetalLayer *old=r->layer;r->layer=[CAMetalLayer layer];r->layer.delegate=(id)view;
    r->layer_generation++;r->display_arm_pending=NO;request(r);
    drainOne(mainTasks);assert(r->display_arm_pending && !r->display_link);
    drainOne(presenterTasks);drainOne(mainTasks);
    assert(r->display_link && !r->display_link.paused && !r->display_arm_pending);
    assert(r->display_link.preferredFrameRateRange.maximum==120);
    assert(r->layer.drawableSize.width==2752 && old.drawableSize.width==2752);
    TestLink *current=r->display_link;TestUpdate *update=[TestUpdate new];update.drawable=[NSObject new];
    [r displayPulse:[TestLink new] update:update];assert(!r->presents);
    r->display_quiesced=YES;[r displayPulse:current update:update];assert(!r->presents);
    r->display_quiesced=NO;r->display_scene_active=NO;
    [r displayPulse:current update:update];assert(!r->presents);
    r->display_scene_active=YES;r->display_link_generation--;
    [r displayPulse:current update:update];assert(!r->presents);
    r->display_link_generation=r->layer_generation;
    [r displayPulse:current update:update];assert(r->presents==1 && r->display_drawable==update.drawable);
    [r displayPulse:current update:update];assert(r->presents==1); // no damage, no duplicate
    // Replacing a layer retires the link and honours the new screen's maximum.
    r->screen_dirty=YES;r->layer=[CAMetalLayer layer];r->layer.delegate=(id)view;r->layer_generation++;
    view.window.screen.maximumFramesPerSecond=60;request(r);drainOne(presenterTasks);drainOne(mainTasks);
    assert(current.invalidated && r->display_link!=current && r->display_link.preferredFrameRateRange.maximum==60);
    // Both active rates use the actual production callback. Even a deadline
    // derived from a late commit cannot reject the next system display pulse.
    r->display_drawable=nil;r->frame_pacing.next=101;
    int before=r->presents;
    for(int i=0;i<120;i++){
        r->screen_dirty=YES;r->display_drawable=nil;
        [r displayPulse:r->display_link update:update];
        assert(r->presents==before+i+1);
    }
    assert(r->display_link.preferredFrameRateRange.minimum==60);
    r->screen_dirty=YES;r->display_drawable=nil;r->presenter_running=YES;
    [r displayPulse:r->display_link update:update];assert(r->presents==before+120 && !r->display_drawable);
    // Full presentation budget retains damage and takes no drawable. The
    // next display pulse after a completion can present the newest state.
    r->presenter_running=NO;atomic_store(&r->presentation_inflight,2);
    [r displayPulse:r->display_link update:update];
    assert(r->screen_dirty&&!r->display_drawable&&atomic_load(&r->presentation_backpressure)==1);
    atomic_store(&r->presentation_inflight,1);
    [r displayPulse:r->display_link update:update];assert(r->presents==before+121&&!r->screen_dirty);
    r->display_drawable=nil;r->screen_dirty=YES;
    r->presenter_running=NO;r->display_pulse_active=YES;
    int preflights=r->preflights;request(r);assert(!presenterTasks.count && r->preflights==preflights);
    r->screen_w=2064;request(r);drainOne(presenterTasks);drainOne(mainTasks);
    assert(r->display_prepared_w==2064 && r->layer.drawableSize.width==2064);
    // MetalFX preflight arms a full output drawable without altering input mode.
    r->desktop_fx=YES;r->screen_w=1280;r->screen_h=960;r->screen_dirty=YES;
    request(r);drainOne(presenterTasks);drainOne(mainTasks);
    assert(r->display_prepared_w==2560 && r->display_prepared_h==1920);
    assert(r->layer.drawableSize.width==2560 && r->layer.drawableSize.height==1920);
    request(r);assert(!presenterTasks.count); // unchanged output never rearms
    // A detached view is never treated as active even without a scene event.
    view.window=nil;r->screen_dirty=YES;r->display_drawable=nil;
    [r displayPulse:r->display_link update:update];
    assert(!r->display_scene_active && !r->display_pulse_active && r->display_link.paused);
    request(r);assert(!presenterTasks.count && !mainTasks.count);
    atomic_store(&r->stopping,1);request(r);assert(!presenterTasks.count);
    puts("display pulses: coalescing, retired generations, scenes, pause, refresh and damage passed");
} }
'''.replace('METHODS',methods)
with tempfile.TemporaryDirectory(prefix='henge-display-pulses-') as folder:
    path=Path(folder);(path/'test.m').write_text(fixture)
    subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-std=c11','-Wall','-Wextra','-Werror',
                    '-fsanitize=address,undefined','-I'+str(root/'devices'),str(path/'test.m'),
                    '-framework','Foundation','-framework','QuartzCore','-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
