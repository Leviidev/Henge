// Runs inside macOS on a Henge virtual Mac, as a LaunchAgent. It keeps the clipboard in step with the device,
// and keeps the shared folder mounted. It talks to host/share.c at 10.0.2.4, which only exists inside Henge.
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
#include <stdatomic.h>
#include <errno.h>

#ifndef HOST
#define HOST "10.0.2.4"
#endif
#ifndef HENGE_SHARE_PORT
#define HENGE_SHARE_PORT 80
#endif

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

// One request on its own connection. A plain socket: the server is ours, and URLSession refuses plain HTTP.
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq) {
    *status = 0;
    static _Atomic int lastConnectionError;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval timeout = {.tv_sec = [path hasPrefix:@"/.henge/native-touch"] ? 5 : ([method isEqual:@"GET"] ? 40 : 4)};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(HENGE_SHARE_PORT)};
    inet_pton(AF_INET, HOST, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        int error = errno;
        if (atomic_exchange(&lastConnectionError, error) != error)
            NSLog(@"Henge sharing connection failed: %d (%s)", error, strerror(error));
        close(fd);
        return nil;
    }
    atomic_store(&lastConnectionError, 0);
    NSString *head = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: " HOST "\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", method, path,
                                                (unsigned long)body.length];
    const char *text = head.UTF8String;
    if (send_all(fd, text, strlen(text)) != 0 || (body.length && send_all(fd, body.bytes, body.length) != 0)) {
        close(fd);
        return nil;
    }
    NSMutableData *all = [NSMutableData data];
    char piece[16384];
    for (;;) {
        ssize_t got = recv(fd, piece, sizeof piece, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0 || all.length + (NSUInteger)MAX(got,0) > 16 * 1024 * 1024 + 32768) { close(fd); return nil; }
        if (got == 0) break;
        [all appendBytes:piece length:(NSUInteger)got];
    }
    close(fd);
    NSRange end = [all rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, all.length)];
    if (end.location == NSNotFound || end.location > 32768) return nil;
    NSString *headers = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    if (!headers || sscanf(headers.UTF8String, "HTTP/1.1 %d", status) != 1) return nil;
    // A timed-out/truncated response must never become a truncated paste.
    NSString *lengthText = nil;
    for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound && [[line substringToIndex:colon.location] caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame)
            lengthText = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    NSScanner *scanner = [NSScanner scannerWithString:lengthText ?: @""];
    unsigned long long length = 0;
    if (!lengthText.length || ![scanner scanUnsignedLongLong:&length] || !scanner.isAtEnd || length != all.length - NSMaxRange(end)) return nil;
    NSRange found = [headers rangeOfString:@"X-Henge-Seq: "];
    if (found.location != NSNotFound && seq) *seq = strtoul(headers.UTF8String + NSMaxRange(found), NULL, 10);
    NSUInteger start = NSMaxRange(end);
    return [all subdataWithRange:NSMakeRange(start, all.length - start)];
}



static NSInteger lastChange;
// Main-thread-owned outgoing state: one upload, newest pending text, bounded retry.
static NSData *pendingClipboard;
static uint64_t pendingRevision;
static BOOL sendingClipboard;
static unsigned clipboardFailures;
static NSTimeInterval retryClipboardAt;
static dispatch_queue_t clipboardUploadQueue;

// The long poll is also the reconnect loop. Establish a baseline immediately,
// then advertise acknowledgement support before accepting an explicit paste.
static void followDevice(void) {
    unsigned long seq = 0;
    BOOL initial = YES;
    for (;;) { @autoreleasepool {
        int status = 0;
        unsigned long now = seq;
        NSString *path = [NSString stringWithFormat:@"/.henge/clipboard?since=%lu&ack=1%@", seq, initial ? @"&initial=1" : @""];
        NSData *body = request(@"GET", path, nil, &status, &now);
        if (!body || (status != 200 && status != 204)) { sleep(2); continue; }
        BOOL news = !initial && status == 200 && now != seq;
        initial = NO; seq = now;
        if (!news) continue;
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!text) continue;
        unsigned long installed = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            if (![board setString:text forType:NSPasteboardTypeString]) return;
            lastChange = board.changeCount;
            // Device paste supersedes an older Mac copy waiting to reconnect.
            pendingClipboard = nil; pendingRevision++;
            dispatch_async(clipboardUploadQueue, ^{ @autoreleasepool {
                NSData *ack = [[NSString stringWithFormat:@"%lu", installed] dataUsingEncoding:NSUTF8StringEncoding];
                for (unsigned attempt = 0; attempt < 3; attempt++) {
                    int code = 0;
                    if (request(@"POST", @"/.henge/clipboard-ack", ack, &code, NULL) && code == 204) break;
                    sleep(1);
                }
            }});
        });
    }}
}

static void uploadClipboard(void) {
    if (sendingClipboard || !pendingClipboard || NSDate.timeIntervalSinceReferenceDate < retryClipboardAt) return;
    NSData *data = pendingClipboard;
    uint64_t revision = pendingRevision;
    sendingClipboard = YES;
    dispatch_async(clipboardUploadQueue, ^{ @autoreleasepool {
        int status = 0;
        BOOL ok = request(@"PUT", @"/.henge/clipboard", data, &status, NULL) != nil && status == 204;
        dispatch_async(dispatch_get_main_queue(), ^{
            sendingClipboard = NO;
            if (revision == pendingRevision && ok) pendingClipboard = nil;
            if (ok) { clipboardFailures = 0; retryClipboardAt = 0; uploadClipboard(); }
            else {
                clipboardFailures = MIN(clipboardFailures + 1, 4u);
                retryClipboardAt = NSDate.timeIntervalSinceReferenceDate + (1u << (clipboardFailures - 1));
            }
        });
    }});
}

// AppKit exposes changeCount, not a change notification for other processes.
// Reuse the existing1Hz lightweight check; no new retry timer or busy polling.
static void checkClipboard(void) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (board.changeCount != lastChange) {
        lastChange = board.changeCount;
        pendingRevision++;
        pendingClipboard = nil;
        if (![board.types containsObject:@"org.nspasteboard.ConcealedType"]) {
            NSString *text = [board stringForType:NSPasteboardTypeString];
            NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
            if (data && data.length <= 16 * 1024 * 1024) pendingClipboard = data;
        }
    }
    uploadClipboard();
}

static NSString *mountPoint(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Henge"]; }

// The shared folder, at ~/Henge. mount_webdav needs an empty folder it owns, and is a no-op failure if it is mounted.
static void keepMounted(void) {
    NSString *point = mountPoint();
    [NSFileManager.defaultManager createDirectoryAtPath:point withIntermediateDirectories:YES attributes:nil error:NULL];
    struct stat folder, parent;
    if (stat(point.fileSystemRepresentation, &folder) != 0 || stat(NSHomeDirectory().fileSystemRepresentation, &parent) != 0) return;
    if (folder.st_dev != parent.st_dev) return; // already something else's volume: mounted
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/mount_webdav"];
    task.arguments = @[ @"-S", @"-v", @"Henge", @"http://" HOST "/", point ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:NULL];
}

// The companion shares this helper's existing private connection. Keep its
// protocol bounded and forward only touch endpoints; it never needs its own
// network access, listening socket, or restricted HID entitlement.
static void launchTouchCompanion(NSString *companion) {
    static _Atomic unsigned restartCount;
    static _Atomic uint64_t restartWindow;
    uint64_t seconds=(uint64_t)NSProcessInfo.processInfo.systemUptime;
    uint64_t window=atomic_load(&restartWindow);
    if(seconds-window>=60){atomic_store(&restartWindow,seconds);atomic_store(&restartCount,0);}
    if(atomic_fetch_add(&restartCount,1)>=5){NSLog(@"Henge touch companion stopped repeatedly; update the helpers to recover.");return;}
    NSTask *touch = [NSTask new];
    NSPipe *commands = [NSPipe pipe], *replies = [NSPipe pipe];
    touch.executableURL = [NSURL fileURLWithPath:companion];
    touch.arguments = @[[NSString stringWithFormat:@"%d", getpid()], @"--stdio"];
    touch.standardInput = replies;
    touch.standardOutput = commands;
    touch.terminationHandler=^(NSTask *ended) {
        NSLog(@"Henge touch companion exited (%d); scheduling bounded restart.",ended.terminationStatus);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{launchTouchCompanion(companion);});
    };
    NSError *launchError=nil;
    if (![touch launchAndReturnError:&launchError]) {
        NSLog(@"Henge touch companion could not launch: %@",launchError.localizedDescription);
        return;
    }
    [commands.fileHandleForWriting closeAndReturnError:NULL];
    [replies.fileHandleForReading closeAndReturnError:NULL];
    NSLock *outputLock = [NSLock new];
    NSFileHandle *input = commands.fileHandleForReading, *output = replies.fileHandleForWriting;
    [NSThread detachNewThreadWithBlock:^{
        NSMutableData *buffer = [NSMutableData data];
        NSData *newline = [NSData dataWithBytes:"\n" length:1];
        for (;;) { @autoreleasepool {
            NSData *chunk = input.availableData;
            if (!chunk.length) break;
            [buffer appendData:chunk];
            if (buffer.length > 16384) { [touch terminate]; break; }
            for (;;) {
                NSRange end = [buffer rangeOfData:newline options:0 range:NSMakeRange(0, buffer.length)];
                if (end.location == NSNotFound) break;
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, end.location)];
                [buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:NULL length:0];
                id decoded = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                if (![decoded isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *message = decoded;
                NSNumber *identifier = message[@"id"];
                NSString *method = message[@"method"], *path = message[@"path"];
                NSString *encodedBody = message[@"body"];
                if (![identifier isKindOfClass:NSNumber.class]) continue;
                BOOL valid = [message[@"version"] isEqual:@1] &&
                    ([method isEqual:@"GET"] || [method isEqual:@"PUT"]) &&
                    ([path isEqual:@"/.henge/native-touch"] || [path isEqual:@"/.henge/native-touch-usb"] ||
                     [path isEqual:@"/.henge/native-touch-usb/report"]) &&
                    (!encodedBody || ([encodedBody isKindOfClass:NSString.class] && encodedBody.length <= 128));
                NSData *body = valid && encodedBody ? [[NSData alloc] initWithBase64EncodedString:encodedBody options:0] : nil;
                valid = valid && (!encodedBody || body) && body.length <= 64;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
                    int status = valid ? 0 : 400;
                    NSData *data = valid ? request(method, path, body, &status, NULL) : nil;
                    NSDictionary *response = @{@"version":@1, @"id":identifier, @"status":@(status),
                        @"body":[(data ?: [NSData data]) base64EncodedStringWithOptions:0]};
                    NSMutableData *encoded = [[NSJSONSerialization dataWithJSONObject:response options:0 error:NULL] mutableCopy];
                    [encoded appendData:newline];
                    [outputLock lock];
                    @try { [output writeData:encoded]; } @catch (NSException *exception) { (void)exception; }
                    [outputLock unlock];
                }});
            }
        }}
        [outputLock lock];
        [output closeAndReturnError:NULL];
        [outputLock unlock];
    }];
}

int main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application finishLaunching];
        // The optional companion binds USB touch to the display and encodes
        // contact lifecycles. Old guests keep the original sharing helper.
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *directory = [bundle.bundleURL.pathExtension isEqual:@"app"] ? bundle.bundleURL.URLByDeletingLastPathComponent.path : bundle.executablePath.stringByDeletingLastPathComponent;
        NSString *companion = [directory stringByAppendingPathComponent:@"Henge Touch Agent.app/Contents/MacOS/henge-touch-agent"];
        if (@available(macOS 15.0, *)) {
            if ([NSFileManager.defaultManager isExecutableFileAtPath:companion]) {
                launchTouchCompanion(companion);
            }
        }
        clipboardUploadQueue = dispatch_queue_create("henge.clipboard.upload", DISPATCH_QUEUE_SERIAL);
        lastChange = NSPasteboard.generalPasteboard.changeCount;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followDevice(); });
        keepMounted();
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; checkClipboard(); }];
        [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) { (void)timer; keepMounted(); }];
        [application run];
    }
    return 0;
}
