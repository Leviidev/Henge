/* Host-side protocol probe; uses the exact header linked into Henge. */
#include <stdio.h>
#include <string.h>
#include "../devices/pvg_shader_broker.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if ((argc == 4 && !strcmp(argv[1], "--cache-only")) ||
            (argc == 5 && (!strcmp(argv[1], "--load-cache") || !strcmp(argv[1], "--load-converted")))) {
            NSString *root = @(argv[2]), *source = @(argv[3]), *route = nil;
            NSMutableArray *attempts = [NSMutableArray new];
            double start = NSProcessInfo.processInfo.systemUptime;
            NSData *data;
            if (argc == 4) data = hv_shader_cached_bytes(root, source);
            else {
                BOOL request = !strcmp(argv[1], "--load-converted");
                NSString *legacy = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"sonoma-ioslib-%@.metallib", source]];
                NSString *marker = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"sonoma-prefer-%@", source]];
                data = hv_shader_load_converted(root, source, legacy, @"test_function", request ||
                    [NSFileManager.defaultManager fileExistsAtPath:marker], request, ^id(NSData *candidate) {
                        NSString *digest = hv_shader_digest(candidate);
                        [attempts addObject:digest];
                        /* Simulates a loader rejecting corrupt data or a library
                         * lacking the requested function; not a Metal oracle. */
                        return [digest isEqual:@(argv[4])] ? candidate : nil;
                    }, &route);
            }
            NSDictionary *result = @{@"length":@(data.length), @"sha256":data ? hv_shader_digest(data) : @"",
                @"seconds":@(NSProcessInfo.processInfo.systemUptime-start), @"route":route ?: @"", @"load_attempts":attempts};
            puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]
                                      encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if (argc != 3 && argc != 4) return 2;
        double start = NSProcessInfo.processInfo.systemUptime;
        NSData *data = hv_shader_converted_bytes(@(argv[1]), @(argv[2]), @"protocol_test");
        NSMutableDictionary *result = [@{@"length":@(data.length), @"sha256":data ? hv_shader_digest(data) : @"",
            @"seconds":@(NSProcessInfo.processInfo.systemUptime-start)} mutableCopy];
        if (argc == 4) {
            start = NSProcessInfo.processInfo.systemUptime;
            NSData *second = hv_shader_converted_bytes(@(argv[1]), @(argv[3]), @"second_shader");
            result[@"second_seconds"] = @(NSProcessInfo.processInfo.systemUptime-start);
            result[@"second_length"] = @(second.length);
        }
        puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]
                                  encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
}
