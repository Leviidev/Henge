/* Run the identical video oracle outside Henge on native iPadOS. This separates
 * guest execution/rendering differences from platform decoder differences. */
#import <UIKit/UIKit.h>
#define main video_pipeline_audit_main
#include "video_pipeline_audit.m"
#undef main

@interface VideoDeviceAuditDelegate : UIResponder <UIApplicationDelegate>
@property(strong) UIWindow *window;
@end
@implementation VideoDeviceAuditDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *view=[UIViewController new];view.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(40,100,1100,400)];label.numberOfLines=0;
    label.text=@"Native iPad video reference starting…";[view.view addSubview:label];
    self.window.rootViewController=view;[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSArray *jobs=@[@[@"h264",@"nv12",@"default"],@[@"h264",@"nv12",@"software"],
                        @[@"hevc",@"nv12",@"default"],@[@"hevc10",@"p010",@"default"]];
        NSMutableArray *completed=[NSMutableArray new];
        for(NSArray *job in jobs) {
            @autoreleasepool {
                NSString *name=[NSString stringWithFormat:@"%@-%@",job[0],job[2]];
                NSString *input=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"AuditData/%@.mp4",job[0]]];
                NSString *output=[documents stringByAppendingPathComponent:[@"VideoPixels/" stringByAppendingString:name]];
                dispatch_async(dispatch_get_main_queue(), ^{label.text=[@"Native video test: " stringByAppendingString:name];});
                writeJSON(@{@"status":@"running",@"current":name,@"completed":completed},[documents stringByAppendingPathComponent:@"video-status.json"]);
                const char *args[]={"video-pipeline-audit",input.UTF8String,output.UTF8String,[job[1] UTF8String],[job[2] UTF8String]};
                int status=video_pipeline_audit_main(5,args);
                [completed addObject:@{@"name":name,@"exit_code":@(status)}];
            }
        }
        writeJSON(@{@"status":@"finished",@"completed":completed},[documents stringByAppendingPathComponent:@"video-status.json"]);
        dispatch_async(dispatch_get_main_queue(), ^{label.text=@"Native video references finished.";});
    });
    return YES;
}
@end
int main(int argc,char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(VideoDeviceAuditDelegate.class)); }
}
