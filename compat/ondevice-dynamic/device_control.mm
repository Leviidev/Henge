#import <UIKit/UIKit.h>
#include <vector>
#define HG_STATELESS_DEVICE_CONTROL 1
#define main HGNativeControlEntry
#include "native_control.mm"
#undef main

@interface HGClosureAudit : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation HGClosureAudit
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [UILabel new]; label.numberOfLines = 0;
    label.text = @"Running on-device stateless closure controls…";
    label.frame = CGRectInset(controller.view.bounds, 50, 50);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:label]; self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        NSString *assets = [NSBundle.mainBundle pathForResource:@"AuditAssets" ofType:nil];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *run = [documents stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSMutableArray *results = [NSMutableArray new];
        NSArray *cases = @[
            @[@"loader", @"consumer-loader.metallib", @"dynamic-loader.metallib", @"0"],
            @[@"absolute", @"consumer-absolute.metallib", @"dynamic-absolute.metallib", @"0", @"source"],
            @[@"preloaded", @"consumer-preloaded.metallib", @"dynamic-control.metallib", @"2", @"source"]
        ];
        BOOL passed = assets != nil;
        for (NSArray *row in cases) {
            NSString *out = [run stringByAppendingPathComponent:row[0]];
            NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"control",
                [assets stringByAppendingPathComponent:row[1]] ?: @"",
                [assets stringByAppendingPathComponent:row[2]] ?: @"", out, row[3]]];
            if (row.count == 5) [args addObject:row[4]];
            std::vector<char *> argv;
            for (NSString *argument in args) argv.push_back((char *)argument.UTF8String);
            int status = HGNativeControlEntry((int)argv.size(), argv.data());
            NSData *bytes = [NSData dataWithContentsOfFile:[out stringByAppendingPathComponent:@"report.json"]];
            NSDictionary *report = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
            passed &= status == 0 && [report[@"mismatches"] intValue] == 0 &&
                [report[@"expected_values"] intValue] == 256 && [report[@"retargeted_to_ios"] boolValue];
            [results addObject:@{@"case":row[0], @"exit":@(status), @"report":report ?: NSNull.null}];
        }
        NSDictionary *summary = @{@"schema":@1, @"passed":@(passed), @"cases":results,
            @"scope":@"Three authored direct iPad Metal controls; no guest adapter or Henge app qualification"};
        NSData *json = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[documents stringByAppendingPathComponent:@"last-result.json"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ label.text = passed
            ? @"Passed: 768 exact compute values, compiled and linked entirely on this iPad."
            : @"A closure control failed. See last-result.json."; });
    }});
    return YES;
}
@end

int main(int argc, char **argv) { @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(HGClosureAudit.class));
}}
