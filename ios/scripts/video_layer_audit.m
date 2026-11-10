/* Bounded visible AVPlayerLayer probe. Source decoding alone is not evidence
 * of correct display: inspect the iPad screenshot during this window. */
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
static id err(NSError *e){return e?@{@"domain":e.domain,@"code":@(e.code),@"description":e.description}:NSNull.null;}
int main(int argc,const char **argv){@autoreleasepool{
 if(argc!=3)return 2;
 NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];[app finishLaunching];
 NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,960,540) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
 window.title=@"Henge video layer audit — closes automatically";window.releasedWhenClosed=NO;[window center];
 NSView *view=window.contentView;view.wantsLayer=YES;
 AVPlayerItem *item=[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:@(argv[1])]];
 AVPlayer *player=[AVPlayer playerWithPlayerItem:item];player.volume=0;player.automaticallyWaitsToMinimizeStalling=NO;
 AVPlayerLayer *layer=[AVPlayerLayer playerLayerWithPlayer:player];layer.frame=view.bounds;layer.autoresizingMask=kCALayerWidthSizable|kCALayerHeightSizable;layer.videoGravity=AVLayerVideoGravityResizeAspect;[view.layer addSublayer:layer];
 [window makeKeyAndOrderFront:nil];[app activateIgnoringOtherApps:YES];[player play];
 double started=NSProcessInfo.processInfo.systemUptime;NSMutableArray *samples=[NSMutableArray new];unsigned next=0;BOOL paused=NO;
 while(NSProcessInfo.processInfo.systemUptime-started<25){
  NSEvent *event=[app nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.02] inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[app sendEvent:event];[app updateWindows];
  double elapsed=NSProcessInfo.processInfo.systemUptime-started,t=CMTimeGetSeconds(item.currentTime);
  if(!paused&&isfinite(t)&&t>=.1){[player pause];paused=YES;}
  if(elapsed>=next){
   [samples addObject:@{@"elapsed":@(elapsed),@"time":isfinite(t)?@(t):NSNull.null,@"item_status":@(item.status),@"ready_for_display":@(layer.readyForDisplay),@"waiting":player.reasonForWaitingToPlay?:@"",@"error":err(item.error)}];next+=2;
   NSDictionary *report=@{@"source":@(argv[1]),@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"samples":samples,@"pixel_correctness":@"requires screenshot; readiness is not proof"};
   [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]writeToFile:@(argv[2]) atomically:YES];
  }
 }
 [player pause];[window orderOut:nil];return item.status==AVPlayerItemStatusFailed?1:0;
}}
