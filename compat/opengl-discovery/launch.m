/* Process-scoped launcher: macOS14 arm64, Foundation/AppKit; no Python/CLT at runtime. */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <unistd.h>
static void fail(NSString *message){fprintf(stderr,"%s\n",message.UTF8String);exit(64);}
static NSString *digest(NSString *path){NSFileHandle*f=[NSFileHandle fileHandleForReadingAtPath:path];if(!f)fail(@"Cannot read input");CC_SHA256_CTX c;CC_SHA256_Init(&c);NSData*d;while((d=[f readDataOfLength:1048576]).length)CC_SHA256_Update(&c,d.bytes,(CC_LONG)d.length);[f closeFile];unsigned char out[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(out,&c);NSMutableString*s=[NSMutableString new];for(unsigned i=0;i<sizeof out;i++)[s appendFormat:@"%02x",out[i]];return s;}
static NSData *run(NSString *executable,NSArray *arguments,int *status){NSTask*t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:executable];t.arguments=arguments;NSPipe*p=[NSPipe pipe];t.standardOutput=p;t.standardError=p;NSError*error=nil;if(![t launchAndReturnError:&error])fail(error.description);NSData*d=[p.fileHandleForReading readDataToEndOfFile];[t waitUntilExit];*status=t.terminationStatus;return d;}
static void save(NSDictionary *value,NSString *path){NSError*error=nil;NSData*d=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];if(!d||![d writeToFile:path options:NSDataWritingAtomic error:&error])fail(error.description);}
/* Activation is optional and bound only to the child we just started.
   A sent request is distinct from observed foreground status. */
static NSDictionary *activateChild(NSTask *task) {
 pid_t pid=task.processIdentifier;
 NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+15.0;
 NSRunningApplication *application=nil;
 while(task.running && NSProcessInfo.processInfo.systemUptime<deadline) {
  application=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  if(application.isFinishedLaunching)break;
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
 }
 BOOL ready=task.running && application.isFinishedLaunching;
 BOOL sent=ready && [application activateWithOptions:NSApplicationActivateAllWindows];
 BOOL foreground=NO;
 deadline=NSProcessInfo.processInfo.systemUptime+2.0;
 while(sent && task.running && NSProcessInfo.processInfo.systemUptime<deadline) {
  foreground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==pid;
  if(foreground)break;
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
 }
 return @{@"requested":@YES,@"pid":@(pid),@"app_ready":@(ready),
  @"request_sent":@(sent),@"observed_frontmost":@(foreground),
  @"status":foreground?@"foreground":!task.running?@"child_exited":!ready?@"readiness_timeout":!sent?@"request_declined":@"foreground_not_observed"};
}
int main(int argc,const char **argv){@autoreleasepool{
 NSMutableDictionary*options=[NSMutableDictionary new];NSMutableArray*additional=[NSMutableArray new],*args=[NSMutableArray new];BOOL dry=NO,activate=NO;
 for(int i=1;i<argc;i++){NSString*k=@(argv[i]);if([k isEqual:@"--"]){for(++i;i<argc;i++)[args addObject:@(argv[i])];break;}if([k isEqual:@"--dry-run"]){dry=YES;continue;}if([k isEqual:@"--activate"]){activate=YES;continue;}
  if(![@[@"--app",@"--executable",@"--shim",@"--receipt",@"--log",@"--additional-dylib"]containsObject:k]||i+1>=argc)fail(@"Usage: launch --shim PATH (--app APP|--executable FILE) --receipt NEW.json --log NEW.log [--additional-dylib PATH] [--dry-run] [--activate] -- [args]");
  NSString*v=[@(argv[++i]) stringByStandardizingPath];if(![v hasPrefix:@"/"])v=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:v];v=v.stringByResolvingSymlinksInPath;
  if([k isEqual:@"--additional-dylib"])[additional addObject:v];else if(options[k])fail(@"Duplicate option");else options[k]=v;
 }
 if(!options[@"--shim"]||!options[@"--receipt"]||!options[@"--log"]||((options[@"--app"]!=nil)==(options[@"--executable"]!=nil)))fail(@"Specify shim, receipt, log and exactly one app or executable");
 NSMutableDictionary*environment=[NSProcessInfo.processInfo.environment mutableCopy];if([environment[@"DYLD_INSERT_LIBRARIES"]length])fail(@"Inherited DYLD_INSERT_LIBRARIES refused; specify additional libraries explicitly");
 NSDictionary*info=@{};NSString*target=options[@"--executable"];
 if(options[@"--app"]){NSString*app=options[@"--app"];info=[NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];NSString*name=info[@"CFBundleExecutable"];if(!name.length||[name containsString:@"/"]||[name isEqual:@".."]||[name isEqual:@"."])fail(@"Invalid app bundle executable");target=[[app stringByAppendingPathComponent:@"Contents/MacOS"]stringByAppendingPathComponent:name];}
 if(![NSFileManager.defaultManager isExecutableFileAtPath:target])fail(@"Target is not executable");
 NSString*receipt=options[@"--receipt"],*log=options[@"--log"];
 if([NSFileManager.defaultManager fileExistsAtPath:receipt]||[NSFileManager.defaultManager fileExistsAtPath:log])fail(@"Receipt/log paths must be new");
 NSMutableArray*libraries=[NSMutableArray arrayWithObject:options[@"--shim"]];[libraries addObjectsFromArray:additional];NSMutableDictionary*hashes=[NSMutableDictionary new];for(NSString*p in libraries){if([p containsString:@":"]||![NSFileManager.defaultManager isReadableFileAtPath:p])fail(@"Library must exist and have a colon-free path");hashes[p]=digest(p);}
 int status=0;NSString*detail=[[NSString alloc]initWithData:run(@"/usr/bin/codesign",@[@"-dv",@"--verbose=4",target],&status)encoding:NSUTF8StringEncoding]?:@"";int signatureStatus=status;
 NSData*entData=run(@"/usr/bin/codesign",@[@"-d",@"--entitlements",@":-",target],&status);NSString*entText=[[NSString alloc]initWithData:entData encoding:NSUTF8StringEncoding]?:@"";NSRange xml=[entText rangeOfString:@"<?xml"];
 NSDictionary*ent=@{};if(xml.location!=NSNotFound){NSData*d=[[entText substringFromIndex:xml.location]dataUsingEncoding:NSUTF8StringEncoding];id value=[NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];if([value isKindOfClass:NSDictionary.class])ent=value;}
 if([detail containsString:@"(runtime)"]&&(![ent[@"com.apple.security.cs.disable-library-validation"]boolValue]||![ent[@"com.apple.security.cs.allow-dyld-environment-variables"]boolValue]))fail(@"Hardened runtime restricts DYLD/library validation. Use a supported app build with both entitlements; this helper does not re-sign apps.");
 NSDictionary*launchEnvironment=info[@"LSEnvironment"];if(launchEnvironment[@"DYLD_INSERT_LIBRARIES"])fail(@"App embeds DYLD injection; review a supported app first");for(NSString*key in launchEnvironment){id v=launchEnvironment[key];if([key isKindOfClass:NSString.class]&&[v isKindOfClass:NSString.class])environment[key]=v;}
 environment[@"DYLD_INSERT_LIBRARIES"]=[libraries componentsJoinedByString:@":"];environment[@"HENGE_CGL_DISCOVERY_TEST"]=@"1";[environment removeObjectForKey:@"HENGE_CGL_SOFTWARE_FALLBACK"];
 NSMutableArray*command=[NSMutableArray arrayWithObject:target];[command addObjectsFromArray:args];NSMutableDictionary*record=[@{@"schema":@1,@"command":command,@"target_sha256":digest(target),@"libraries":hashes,@"signature":@{@"codesign_status":@(signatureStatus),@"details":detail,@"entitlements":ent},@"environment_overrides":@{@"DYLD_INSERT_LIBRARIES":environment[@"DYLD_INSERT_LIBRARIES"],@"HENGE_CGL_DISCOVERY_TEST":@"1",@"HENGE_CGL_SOFTWARE_FALLBACK":NSNull.null},@"dry_run":@(dry),@"activation":@{@"requested":@(activate)},@"scope":@"Fresh direct process, no installed/global changes; renderer success requires observed output"}mutableCopy];
 NSError*error=nil;[NSFileManager.defaultManager createDirectoryAtPath:receipt.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];save(record,receipt);if(dry)return 0;
 [NSFileManager.defaultManager createDirectoryAtPath:log.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];if(![NSFileManager.defaultManager createFileAtPath:log contents:NSData.data attributes:@{NSFilePosixPermissions:@0600}])fail(@"Cannot create log");NSFileHandle*handle=[NSFileHandle fileHandleForWritingAtPath:log];NSTask*t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:target];t.arguments=args;t.environment=environment;t.standardOutput=handle;t.standardError=handle;if(![t launchAndReturnError:&error])fail(error.description);
 record[@"child_pid"]=@(t.processIdentifier);record[@"launcher_pid"]=@(getpid());
 save(record,receipt); /* publish exact child identity while it is still running */
 if(activate){record[@"activation"]=activateChild(t);save(record,receipt);}
 [t waitUntilExit];[handle closeFile];record[@"exit_code"]=@(t.terminationStatus);save(record,receipt);return t.terminationStatus;
}}
