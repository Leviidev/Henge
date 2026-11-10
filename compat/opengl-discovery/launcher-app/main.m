/* Clickable shell around the reviewed generic launcher. No injection policy
   lives here: launch performs target signature/restriction checks unchanged. */
#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <unistd.h>

static void saveJSON(NSDictionary *record, NSString *path) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    [bytes writeToFile:path options:NSDataWritingAtomic error:nil];
}
static int reportFailure(NSString *message, NSString *folder, BOOL diagnostic, int status) {
    fprintf(stderr,"%s\n",message.UTF8String);
    if (!diagnostic) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSAlert *alert=[NSAlert new];
        alert.messageText=NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"Henge OpenGL Launcher";
        alert.informativeText=folder.length ? [message stringByAppendingFormat:@"\n\nLogs: %@",folder] : message;
        [alert addButtonWithTitle:@"OK"];
        if(folder.length)[alert addButtonWithTitle:@"Show Logs"];
        [NSApp activateIgnoringOtherApps:YES];
        if([alert runModal]==NSAlertSecondButtonReturn)
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:folder]]];
    }
    return status;
}
int main(int argc,const char **argv) { @autoreleasepool {
    BOOL diagnostic=NO; NSString *diagnosticRoot=nil;
    for(int i=1;i<argc;i++) {
        NSString *arg=@(argv[i]);
        if([arg isEqual:@"--preflight-only"])diagnostic=YES;
        else if([arg isEqual:@"--diagnostic-log-root"] && i+1<argc)diagnosticRoot=@(argv[++i]);
        else return reportFailure(@"Unknown launcher argument.",nil,YES,64);
    }
    if(diagnosticRoot && (!diagnostic || !diagnosticRoot.isAbsolutePath))
        return reportFailure(@"An absolute diagnostic log root requires --preflight-only.",nil,YES,64);
    NSBundle *bundle=NSBundle.mainBundle;
    NSString *target=bundle.infoDictionary[@"HengeTargetExecutable"];
    NSString *targetBundleID=bundle.infoDictionary[@"HengeTargetBundleIdentifier"];
    NSString *launch=[bundle pathForResource:@"launch" ofType:nil];
    NSString *shim=[bundle pathForResource:@"registry-discovery" ofType:@"dylib"];
    NSFileManager *files=NSFileManager.defaultManager;
    if(![target isKindOfClass:NSString.class] || !target.isAbsolutePath || !launch || !shim ||
       ![files isExecutableFileAtPath:launch] || ![files isReadableFileAtPath:shim])
        return reportFailure(@"The configured target or bundled launcher resources are missing.",nil,diagnostic,64);
    NSString *library=NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,NSUserDomainMask,YES).firstObject;
    NSString *root=diagnosticRoot ?: [library stringByAppendingPathComponent:@"Logs/Henge/OpenGL"];
    NSDateFormatter *format=[NSDateFormatter new];format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat=@"yyyyMMdd-HHmmss";
    NSString *run=[NSString stringWithFormat:@"%@-%@",[format stringFromDate:NSDate.date],NSUUID.UUID.UUIDString];
    NSString *folder=[root stringByAppendingPathComponent:run];NSError *error=nil;
    if(![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error])
        return reportFailure(error.localizedDescription,nil,diagnostic,73);
    NSMutableArray *arguments=[NSMutableArray arrayWithArray:@[@"--executable",target,@"--shim",shim,
        @"--receipt",[folder stringByAppendingPathComponent:@"receipt.json"],
        @"--log",[folder stringByAppendingPathComponent:@"target.log"],@"--activate"]];
    if(diagnostic)[arguments addObject:@"--dry-run"];
    NSMutableDictionary *record=[@{@"schema":@1,@"bundle":bundle.bundlePath,@"target":target,
        @"launcher":launch,@"arguments":arguments,@"preflight_only":@(diagnostic),
        @"scope":@"Wrapper does not modify the configured target app or its preferences; the launched app retains its ordinary behavior"} mutableCopy];
    NSString *recordPath=[folder stringByAppendingPathComponent:@"wrapper.json"];
    saveJSON(record,recordPath);
    printf("%s\n",folder.UTF8String);fflush(stdout);
    if(!diagnostic && [targetBundleID isKindOfClass:NSString.class] && targetBundleID.length &&
       [NSRunningApplication runningApplicationsWithBundleIdentifier:targetBundleID].count) {
        record[@"error"]=@"Target app already running";saveJSON(record,recordPath);
        return reportFailure(@"Quit the running target app, then open this launcher again to start a fresh session through this launcher.",folder,NO,75);
    }
    NSString *launcherLog=[folder stringByAppendingPathComponent:@"launcher.log"];
    int fd=open(launcherLog.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0)return reportFailure(@"Could not create the launcher log.",folder,diagnostic,73);
    NSFileHandle *log=[[NSFileHandle alloc]initWithFileDescriptor:fd closeOnDealloc:YES];
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:launch];task.arguments=arguments;
    task.standardOutput=log;task.standardError=log;
    /* Inherit the environment intact. The generic launcher deliberately
       rejects inherited DYLD injection; this wrapper must not bypass it. */
    if(![task launchAndReturnError:&error]) {
        record[@"error"]=error.localizedDescription ?: @"launch failed";saveJSON(record,recordPath);
        return reportFailure(record[@"error"],folder,diagnostic,71);
    }
    [task waitUntilExit];[log closeFile];
    record[@"exit_code"]=@(task.terminationStatus);saveJSON(record,recordPath);
    if(task.terminationStatus)
        return reportFailure([NSString stringWithFormat:@"The launcher exited with status %d. See launcher.log for the reason.",task.terminationStatus],folder,diagnostic,task.terminationStatus);
    return 0;
} }
