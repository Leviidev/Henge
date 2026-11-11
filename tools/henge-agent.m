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

#define HOST "10.0.2.4"

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

// One request on its own connection. A plain socket: the server is ours, and URLSession refuses plain HTTP.
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq) {
    static _Atomic int lastConnectionError;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval timeout = {.tv_sec = [path hasPrefix:@"/.henge/native-touch"] ? 1 : 40};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(80)};
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
        if (got <= 0) break;
        [all appendBytes:piece length:(NSUInteger)got];
    }
    close(fd);
    NSRange end = [all rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, all.length)];
    if (end.location == NSNotFound) return nil;
    NSString *headers = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    if (sscanf(headers.UTF8String, "HTTP/1.1 %d", status) != 1) return nil;
    NSRange found = [headers rangeOfString:@"X-Henge-Seq: "];
    if (found.location != NSNotFound && seq) *seq = strtoul(headers.UTF8String + NSMaxRange(found), NULL, 10);
    NSUInteger start = NSMaxRange(end);
    return [all subdataWithRange:NSMakeRange(start, all.length - start)];
}

static NSInteger lastChange;

// The device's clipboard, as it changes. The server holds each request until there is something new.
static void followDevice(void) {
    unsigned long seq = 0;
    for (BOOL first = YES;; first = NO) {
        int status = 0;
        unsigned long now = seq;
        NSData *body = request(@"GET", [NSString stringWithFormat:@"/.henge/clipboard?since=%lu", first ? ULONG_MAX >> 1 : seq], nil, &status, &now);
        if (!body) {
            sleep(5);
            continue;
        }
        BOOL news = !first && status == 200 && now != seq;
        seq = now; // what the device had before this helper started isn't news
        if (!news) continue;
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!text) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            lastChange = board.changeCount;
        });
    }
}

// The Mac's clipboard goes to the device, unless the app that copied it marked it as secret.
static void checkClipboard(void) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (board.changeCount == lastChange) return;
    lastChange = board.changeCount;
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"]) return;
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"PUT", @"/.henge/clipboard", data, &status, NULL);
    });
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
    NSTask *touch = [NSTask new];
    NSPipe *commands = [NSPipe pipe], *replies = [NSPipe pipe];
    touch.executableURL = [NSURL fileURLWithPath:companion];
    touch.arguments = @[[NSString stringWithFormat:@"%d", getpid()], @"--stdio"];
    touch.standardInput = replies;
    touch.standardOutput = commands;
    if (![touch launchAndReturnError:NULL]) return;
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
        lastChange = NSPasteboard.generalPasteboard.changeCount;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followDevice(); });
        keepMounted();
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; checkClipboard(); }];
        [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) { (void)timer; keepMounted(); }];
        [application run];
    }
    return 0;
}
