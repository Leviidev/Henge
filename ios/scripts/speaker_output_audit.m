/* Acoustic verification of a known three-tone test. Stores level/target-band
 * energies only: no microphone waveform, speech or audio recording is saved. */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <math.h>

@interface SpeakerAudit : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@property UILabel *label;
@property AVAudioEngine *engine;
@property AVAudioPlayer *player;
@property NSMutableArray *samples;
@property NSString *mode;
@property NSString *root;
@property double began;
@property BOOL capturing;
@property double duration;
@property NSArray<NSNumber *> *bands;
@end
@implementation SpeakerAudit
- (void)save:(NSString *)status error:(NSString *)error {
    AVAudioSession *session=AVAudioSession.sharedInstance;
    NSArray *rows;@synchronized(self){rows=[self.samples copy] ?: @[];}
    NSDictionary *record=@{@"schema":@1,@"status":status,@"mode":self.mode?:@"unknown",@"error":error?:@"",
        @"route":session.currentRoute.description,@"output_volume":@(session.outputVolume),
        @"sample_rate":@(session.sampleRate),@"duration_seconds":@(self.duration),@"bands_hz":self.bands,
        @"samples":rows,@"raw_audio_saved":@NO};
    NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[self.root stringByAppendingPathComponent:[NSString stringWithFormat:@"speaker-%@.json",self.mode]] options:NSDataWritingAtomic error:nil];
    self.label.text=[NSString stringWithFormat:@"Speaker test: %@\n%@\nOnly test-tone levels are retained.",self.mode,status];
}
- (void)start {
    NSError *error=nil;AVAudioSession *session=AVAudioSession.sharedInstance;
    if(![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionDefaultToSpeaker error:&error] ||
       ![session setActive:YES error:&error]){[self save:@"session_failed" error:error.description];return;}
    self.engine=[AVAudioEngine new];AVAudioInputNode *input=self.engine.inputNode;
    AVAudioFormat *format=[input outputFormatForBus:0];
    if(!format.sampleRate||!format.channelCount){[self save:@"no_microphone_format" error:nil];return;}
    self.samples=[NSMutableArray new];self.began=NSProcessInfo.processInfo.systemUptime;self.capturing=YES;
    __weak SpeakerAudit *weak=self;
    [input installTapOnBus:0 bufferSize:2048 format:format block:^(AVAudioPCMBuffer *buffer,AVAudioTime *when){
        SpeakerAudit *strong=weak;if(!strong||!strong.capturing||!buffer.floatChannelData||!buffer.frameLength)return;
        const float *p=buffer.floatChannelData[0];NSUInteger n=buffer.frameLength;double fs=buffer.format.sampleRate;
        double squared=0;for(NSUInteger i=0;i<n;i++)squared+=(double)p[i]*p[i];
        NSMutableArray *power=[NSMutableArray new];
        for(unsigned band=0;band<4;band++){
            double c=2*cos(2*M_PI*strong.bands[band].doubleValue/fs),q1=0,q2=0;
            for(NSUInteger i=0;i<n;i++){double q=p[i]+c*q1-q2;q2=q1;q1=q;}
            double value=fmax(0,q1*q1+q2*q2-c*q1*q2)/(n*n);[power addObject:@(value)];
        }
        NSDictionary *row=@{@"seconds":@(NSProcessInfo.processInfo.systemUptime-strong.began),@"rms":@(sqrt(squared/n)),@"band_power":power,@"frames":@(n)};
        @synchronized(strong){if(strong.samples.count<2000)[strong.samples addObject:row];}
    }];
    if(![self.engine startAndReturnError:&error]){self.capturing=NO;[self save:@"engine_failed" error:error.description];return;}
    if([self.mode isEqualToString:@"native"]){
        self.player=[[AVAudioPlayer alloc]initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"speaker-tones" withExtension:@"wav"] error:&error];
        self.player.volume=1;self.player.numberOfLoops=-1;
        if(![self.player play]){[self save:@"native_player_failed" error:error.description];return;}
    }
    [self save:@"running" error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.duration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        self.capturing=NO;[self.player stop];[self.engine.inputNode removeTapOnBus:0];[self.engine stop];
        [self save:@"finished" error:nil];
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    });
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.root=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *mode=[[NSString stringWithContentsOfFile:[self.root stringByAppendingPathComponent:@"speaker-mode.txt"] encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.mode=[mode isEqualToString:@"guest"]?@"guest":@"native";
    double duration=[[NSString stringWithContentsOfFile:[self.root stringByAppendingPathComponent:@"speaker-duration.txt"] encoding:NSUTF8StringEncoding error:nil] doubleValue];
    self.duration=duration>=5&&duration<=120?duration:20;
    self.bands=@[@650,@1100,@1750,@2500];
    NSData *bandData=[NSData dataWithContentsOfFile:[self.root stringByAppendingPathComponent:@"speaker-bands.json"]];
    id bands=bandData?[NSJSONSerialization JSONObjectWithData:bandData options:0 error:nil]:nil;
    if([bands isKindOfClass:NSArray.class]&&[bands count]==4){
        BOOL valid=YES;for(id value in bands)if(![value isKindOfClass:NSNumber.class]||[value doubleValue]<50||[value doubleValue]>20000)valid=NO;
        if(valid)self.bands=bands;
    }
    self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];UIViewController *view=[UIViewController new];view.view.backgroundColor=UIColor.blackColor;
    self.label=[[UILabel alloc]initWithFrame:view.view.bounds];self.label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.label.textColor=UIColor.whiteColor;self.label.numberOfLines=0;self.label.textAlignment=NSTextAlignmentCenter;[view.view addSubview:self.label];self.window.rootViewController=view;[self.window makeKeyAndVisible];
    [self save:@"waiting_for_microphone" error:nil];
    [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted){dispatch_async(dispatch_get_main_queue(),^{if(granted)[self start];else [self save:@"microphone_denied" error:nil];});}];
    return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(SpeakerAudit.class));}}
