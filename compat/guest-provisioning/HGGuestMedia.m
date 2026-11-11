#import <Foundation/Foundation.h>
#include "HGGuestMedia.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef unsigned int HGIOObject;
typedef struct {
    CFMutableDictionaryRef (*matching)(const char *);
    int (*services)(unsigned int, CFDictionaryRef, HGIOObject *);
    HGIOObject (*next)(HGIOObject);
    int (*release)(HGIOObject);
    int (*properties)(HGIOObject, CFMutableDictionaryRef *, CFAllocatorRef, unsigned int);
    CFTypeRef (*search)(HGIOObject, const char *, CFStringRef, CFAllocatorRef, unsigned int);
    int (*identifier)(HGIOObject, uint64_t *);
} HGIOAPI;

static NSString *image_path(id value)
{
    if ([value isKindOfClass:NSData.class]) {
        NSData *data = value;
        if (!data.length || data.length > PATH_MAX) return nil;
        const unsigned char *bytes = data.bytes;
        NSUInteger length = data.length;
        if (!bytes[length - 1]) length--;
        if (!length || memchr(bytes, 0, length)) return nil;
        value = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    }
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"/"] ||
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= PATH_MAX) return nil;
    const char *utf8 = [value UTF8String];
    if (!utf8 || strlen(utf8) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return nil;
    return value;
}

static BOOL bsd_name(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || name.length > 63 || ![name hasPrefix:@"disk"]) return NO;
    const char *utf8 = name.UTF8String;
    if (!utf8 || strlen(utf8) != [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return NO;
    const char *p = utf8 + 4;
    for (;;) {
        if (*p < '0' || *p > '9') return NO;
        while (*p >= '0' && *p <= '9') p++;
        if (!*p) return YES;
        if (*p++ != 's') return NO;
    }
}

int hg_guest_media_copy(const HGGuestDisk *disk, char **json, const char **error)
{
    if (json) *json = NULL;
    if (error) *error = "media-inventory-failed";
    if (!disk || !json || !error || !hg_guest_disk_unchanged(disk)) return -1;
    @autoreleasepool {
        void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        if (!library) return -1;
        HGIOAPI api = {
            .matching = dlsym(library, "IOServiceMatching"),
            .services = dlsym(library, "IOServiceGetMatchingServices"),
            .next = dlsym(library, "IOIteratorNext"),
            .release = dlsym(library, "IOObjectRelease"),
            .properties = dlsym(library, "IORegistryEntryCreateCFProperties"),
            .search = dlsym(library, "IORegistryEntrySearchCFProperty"),
            .identifier = dlsym(library, "IORegistryEntryGetRegistryEntryID")
        };
        if (!api.matching || !api.services || !api.next || !api.release ||
            !api.properties || !api.search || !api.identifier) { dlclose(library); return -1; }
        HGIOObject iterator = 0;
        CFMutableDictionaryRef match = api.matching("IOMedia");
        if (!match) { dlclose(library); return -1; }
        // IOServiceGetMatchingServices consumes the matching dictionary.
        if (api.services(0, match, &iterator) || !iterator) {
            if (iterator) api.release(iterator);
            dlclose(library); return -1;
        }
        NSMutableArray *rows = [NSMutableArray array];
        NSMutableSet *names = [NSMutableSet set];
        BOOL failed = NO;
        unsigned int count = 0;
        HGIOObject entry;
        while ((entry = api.next(iterator))) {
            if (++count > 4096) { api.release(entry); failed = YES; break; }
            // Parent + recursive search: only an image-backed ancestor grants a
            // candidate identity. Device names and hdik output grant none.
            CFTypeRef ancestor = api.search(entry, "IOService", CFSTR("image-path"), NULL, 3);
            if (!ancestor) { api.release(entry); continue; }
            NSString *path = image_path((__bridge id)ancestor);
            int fd = path ? open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) : -1;
            struct stat info;
            BOOL readable = fd >= 0 && !fstat(fd, &info) && S_ISREG(info.st_mode);
            BOOL owned = readable && info.st_dev == disk->identity.st_dev && info.st_ino == disk->identity.st_ino;
            if (fd >= 0) close(fd);
            CFRelease(ancestor);
            // An unresolvable ancestor might be this image under a renamed or
            // removed path. Do not claim an empty inventory in that case.
            if (!readable) { api.release(entry); failed = YES; break; }
            if (!owned) { api.release(entry); continue; }
            CFMutableDictionaryRef properties = NULL;
            uint64_t identifier = 0;
            int result = api.properties(entry, &properties, NULL, 0);
            int identified = api.identifier(entry, &identifier);
            api.release(entry);
            NSDictionary *p = CFBridgingRelease(properties);
            NSString *name = p[@"BSD Name"], *content = p[@"Content"];
            id size = p[@"Size"], whole = p[@"Whole"], leaf = p[@"Leaf"], writable = p[@"Writable"];
            if (result || identified || !identifier || ![p isKindOfClass:NSDictionary.class] ||
                !bsd_name(name) || [names containsObject:name] || rows.count >= 128 ||
                ![content isKindOfClass:NSString.class] || !content.length || content.length > 128 ||
                ![size isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)size) != CFNumberGetTypeID() ||
                CFNumberIsFloatType((__bridge CFNumberRef)size) || [size longLongValue] <= 0 ||
                ![whole isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)whole) != CFBooleanGetTypeID() ||
                ![leaf isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)leaf) != CFBooleanGetTypeID() ||
                ![writable isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)writable) != CFBooleanGetTypeID()) {
                failed = YES; break;
            }
            [names addObject:name];
            [rows addObject:@{@"bsd_name": name, @"content": content, @"bytes": size,
                              @"whole": whole, @"leaf": leaf, @"writable": writable,
                              @"registry_id": @(identifier)}];
        }
        api.release(iterator);
        dlclose(library);
        if (failed || !hg_guest_disk_unchanged(disk)) return -1;
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"bsd_name"] compare:b[@"bsd_name"] options:NSLiteralSearch];
        }];
        NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingSortedKeys error:NULL];
        if (!data || data.length > 32768) return -1;
        *json = strndup(data.bytes, data.length);
        if (!*json) return -1;
        *error = NULL;
        return 0;
    }
}
