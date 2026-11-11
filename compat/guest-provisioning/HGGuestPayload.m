#import <Foundation/Foundation.h>
#include "HGGuestPayload.h"
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static const NSUInteger HGMaxArchive = 16 * 1024 * 1024;
static const NSUInteger HGMaxExpanded = 32 * 1024 * 1024;

static NSArray<NSString *> *executables(void) {
    return @[@"libHengeDynamic.dylib", @"libHengeCGLDiscovery.dylib",
             @"libaacdecgap_plugin.dylib", @"libaacgap_plugin.dylib",
             @"libaacpacketgap_plugin.dylib", @"libavgap_plugin.dylib",
             @"libmacosx_plugin.dylib", @"libmux_mp4_plugin.dylib",
             @"libsamplerate_plugin.dylib", @"libstream_out_transcode_plugin.dylib",
             @"libx265_plugin.dylib"];
}

static NSSet<NSString *> *files(void) {
    NSMutableSet *names = [NSMutableSet setWithArray:executables()];
    [names addObjectsFromArray:@[@"LICENSE-Henge-GPL-2.0.txt", @"LICENSE-VLC-GPL-2.0.txt",
        @"LICENSE-VLC-LGPL-2.1.txt", @"LICENSE-FFmpeg-LGPL-2.1.txt",
        @"LICENSE-x265-GPL-2.0.txt", @"LICENSE-libsamplerate-BSD.txt", @"vlc-build-receipt.json"]];
    return names;
}

static BOOL hex(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

static NSString *sha(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(bytes); ++i) [result appendFormat:@"%02x", bytes[i]];
    return result;
}

static BOOL keys(id object, NSArray *expected) {
    return [object isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:[object allKeys]] isEqualToSet:[NSSet setWithArray:expected]];
}

static BOOL number(id value, uint64_t expected) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value isEqualToNumber:@(expected)];
}

static NSData *read_member(int directory, const char *name, NSUInteger limit) {
    int fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        (uint64_t)info.st_size > limit) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return nil; }
        offset += (size_t)n;
    }
    unsigned char extra;
    ssize_t trailing;
    do { trailing = read(fd, &extra, 1); } while (trailing < 0 && errno == EINTR);
    close(fd);
    return trailing == 0 ? data : nil;
}

static NSData *expand(NSData *compressed) {
    z_stream stream = {0};
    if (inflateInit2(&stream, 15 + 16) != Z_OK) return nil;
    stream.next_in = (Bytef *)compressed.bytes;
    stream.avail_in = (uInt)compressed.length;
    NSMutableData *result = [NSMutableData data];
    unsigned char chunk[65536];
    BOOL valid = NO;
    for (;;) {
        uInt before = stream.avail_in;
        stream.next_out = chunk;
        stream.avail_out = sizeof(chunk);
        int status = inflate(&stream, Z_NO_FLUSH);
        NSUInteger produced = sizeof(chunk) - stream.avail_out;
        if (produced > HGMaxExpanded - result.length) break;
        [result appendBytes:chunk length:produced];
        if (status == Z_STREAM_END) { valid = stream.avail_in == 0; break; }
        if (status != Z_OK || (!produced && before == stream.avail_in)) break;
    }
    inflateEnd(&stream);
    return valid ? result : nil;
}

static BOOL zero(const unsigned char *bytes, NSUInteger count) {
    for (NSUInteger i = 0; i < count; ++i) if (bytes[i]) return NO;
    return YES;
}

static BOOL octal(const unsigned char *bytes, NSUInteger count, uint64_t *out) {
    uint64_t value = 0;
    BOOL ended = NO, digit = NO;
    for (NSUInteger i = 0; i < count; ++i) {
        unsigned char c = bytes[i];
        if (c == 0 || c == ' ') { ended = YES; continue; }
        if (ended || c < '0' || c > '7' || value > (UINT64_MAX >> 3)) return NO;
        value = (value << 3) + c - '0';
        digit = YES;
    }
    if (!digit) return NO;
    *out = value;
    return YES;
}

static NSDictionary<NSString *, NSData *> *untar(NSData *tar) {
    if (tar.length % 512) return nil;
    const unsigned char *bytes = tar.bytes;
    NSMutableSet *expected = [files() mutableCopy];
    [expected addObject:@"manifest.json"];
    NSMutableDictionary *members = [NSMutableDictionary dictionary];
    NSUInteger offset = 0;
    while (offset + 512 <= tar.length) {
        const unsigned char *h = bytes + offset;
        if (zero(h, 512)) {
            if (tar.length - offset < 1024 || !zero(h, tar.length - offset)) return nil;
            return members.count == expected.count &&
                [[NSSet setWithArray:members.allKeys] isEqualToSet:expected] ? [members copy] : nil;
        }
        const unsigned char *end = memchr(h, 0, 100);
        if (!end || !zero(end, 100 - (NSUInteger)(end - h))) return nil;
        NSString *name = [[NSString alloc] initWithBytes:h length:(NSUInteger)(end - h)
                                              encoding:NSASCIIStringEncoding];
        if (!name || ![expected containsObject:name] || members[name]) return nil;
        uint64_t mode, uid, gid, size, mtime, checksum;
        if (!octal(h + 100, 8, &mode) || !octal(h + 108, 8, &uid) ||
            !octal(h + 116, 8, &gid) || !octal(h + 124, 12, &size) ||
            !octal(h + 136, 12, &mtime) || !octal(h + 148, 8, &checksum)) return nil;
        uint64_t sum = 0;
        for (NSUInteger i = 0; i < 512; ++i) sum += i >= 148 && i < 156 ? ' ' : h[i];
        uint64_t wantedMode = [executables() containsObject:name] ? 0755 : 0644;
        if (sum != checksum || mode != wantedMode || uid || gid || mtime || !zero(h + 329, 16) ||
            size > HGMaxArchive || h[156] != '0' || !zero(h + 157, 100) ||
            memcmp(h + 257, "ustar\0", 6) || memcmp(h + 263, "00", 2) ||
            !zero(h + 265, 64) || !zero(h + 345, 167)) return nil;
        offset += 512;
        if (size > tar.length - offset) return nil;
        NSUInteger padded = ((NSUInteger)size + 511) & ~(NSUInteger)511;
        if (padded > tar.length - offset || !zero(bytes + offset + size, padded - size)) return nil;
        members[name] = [tar subdataWithRange:NSMakeRange(offset, (NSUInteger)size)];
        offset += padded;
    }
    return nil;
}

static NSDictionary *object(NSData *data) {
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

static NSDictionary *validate(int directory, const HGGuestPayloadIdentity *idn, NSString **failure,
                              NSDictionary **verifiedMembers) {
#define REQUIRE(condition, message) do { if (!(condition)) { *failure = (message); return nil; } } while (0)
    NSString *descriptorSHA = idn->descriptor_sha256 ? @(idn->descriptor_sha256) : @"";
    NSString *recipe = idn->compiler_recipe ? @(idn->compiler_recipe) : @"";
    NSString *payloadID = idn->payload_id ? @(idn->payload_id) : @"";
    NSString *core = idn->vlc_core_sha256 ? @(idn->vlc_core_sha256) : @"";
    NSString *lock = idn->vlc_reference_lock_sha256 ? @(idn->vlc_reference_lock_sha256) : @"";
    REQUIRE(hex(descriptorSHA) && hex(recipe) && hex(payloadID) && hex(core) && hex(lock), @"unbound-build-identity");
    NSData *descriptorBytes = read_member(directory, "henge-guest-payload.json", 65536);
    REQUIRE(descriptorBytes && [sha(descriptorBytes) isEqual:descriptorSHA], @"descriptor-identity");
    NSDictionary *descriptor = object(descriptorBytes);
    REQUIRE(keys(descriptor, @[@"schema", @"payload_id", @"compiler_recipe", @"archive_sha256",
        @"archive_bytes", @"manifest_sha256", @"activation"]) && number(descriptor[@"schema"], 1) &&
        [descriptor[@"payload_id"] isEqual:payloadID] && [descriptor[@"compiler_recipe"] isEqual:recipe] &&
        [descriptor[@"activation"] isEqual:@"unimplemented"] && hex(descriptor[@"archive_sha256"]) &&
        hex(descriptor[@"manifest_sha256"]), @"descriptor-profile");
    NSData *archive = read_member(directory, "henge-guest-payload.tar.gz", HGMaxArchive);
    REQUIRE(archive && number(descriptor[@"archive_bytes"], archive.length) &&
        [sha(archive) isEqual:descriptor[@"archive_sha256"]], @"archive-identity");
    NSData *expanded = expand(archive);
    REQUIRE(expanded, @"gzip-format-or-bound");
    NSDictionary<NSString *, NSData *> *members = untar(expanded);
    REQUIRE(members, @"tar-format-or-inventory");
    NSData *manifestBytes = members[@"manifest.json"];
    REQUIRE(manifestBytes.length <= 65536 && [sha(manifestBytes) isEqual:descriptor[@"manifest_sha256"]], @"manifest-identity");
    NSDictionary *manifest = object(manifestBytes);
    REQUIRE(keys(manifest, @[@"schema", @"kind", @"architecture", @"minimum_macos", @"compiler_recipe",
        @"sources", @"files", @"activation", @"payload_id", @"vlc"]) && number(manifest[@"schema"], 1) &&
        [manifest[@"kind"] isEqual:@"henge-sonoma-guest-compatibility"] &&
        [manifest[@"architecture"] isEqual:@"arm64"] && [manifest[@"minimum_macos"] isEqual:@"14.0"] &&
        [manifest[@"compiler_recipe"] isEqual:recipe] && [manifest[@"payload_id"] isEqual:payloadID] &&
        [manifest[@"activation"] isEqual:@"unimplemented"], @"manifest-profile");
    NSDictionary *vlc = manifest[@"vlc"];
    NSArray *plugins = [executables() subarrayWithRange:NSMakeRange(2, 9)];
    REQUIRE(keys(vlc, @[@"version", @"bundle_identifier", @"reference_core_sha256", @"reference_lock_sha256",
        @"plugins", @"installation"]) && [vlc[@"version"] isEqual:@"3.0.24"] &&
        [vlc[@"bundle_identifier"] isEqual:@"org.videolan.vlc"] &&
        [vlc[@"reference_core_sha256"] isEqual:core] && [vlc[@"reference_lock_sha256"] isEqual:lock] &&
        [vlc[@"plugins"] isEqual:plugins] && [vlc[@"installation"] isEqual:@"unimplemented"], @"vlc-unit-identity");
    NSDictionary *sourceHashes = manifest[@"sources"];
    REQUIRE([sourceHashes isKindOfClass:NSDictionary.class] && sourceHashes.count > 0 && sourceHashes.count <= 128, @"source-inventory");
    for (id name in sourceHashes) {
        REQUIRE([name isKindOfClass:NSString.class] && [name length] && ![name hasPrefix:@"/"] &&
            ![[name pathComponents] containsObject:@".."] && hex(sourceHashes[name]), @"source-identity");
    }
    NSDictionary *inventory = manifest[@"files"];
    REQUIRE([inventory isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:inventory.allKeys] isEqualToSet:files()], @"manifest-inventory");
    for (NSString *name in files()) {
        NSDictionary *record = inventory[name];
        NSData *data = members[name];
        REQUIRE(keys(record, @[@"sha256", @"bytes", @"mode"]) && hex(record[@"sha256"]) &&
            [sha(data) isEqual:record[@"sha256"]] && number(record[@"bytes"], data.length) &&
            number(record[@"mode"], [executables() containsObject:name] ? 0755 : 0644), @"member-identity");
    }
    if (verifiedMembers) *verifiedMembers = members;
    return @{@"payload_id": payloadID, @"compiler_recipe": recipe, @"members": @(members.count)};
#undef REQUIRE
}

int hg_guest_payload_verify_directory(const char *directory, const HGGuestPayloadIdentity *identity, char **report) {
    @autoreleasepool {
        if (report) *report = NULL;
        NSString *failure = @"resource-directory";
        NSDictionary *validated = nil;
        int fd = directory ? open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
        if (fd >= 0) {
            if (identity) validated = validate(fd, identity, &failure, NULL);
            close(fd);
        }
        NSMutableDictionary *result = [@{@"schema": @1, @"operation": @"verify-payload-v1",
            @"payload_verified": validated ? @YES : @NO, @"guest_disk_accessed": @NO} mutableCopy];
        if (validated) [result addEntriesFromDictionary:validated];
        else result[@"error"] = failure;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if (report && json) *report = strndup(json.bytes, json.length);
        return validated ? 0 : 65;
    }
}

static BOOL staged_members_match(int directory, NSDictionary<NSString *, NSData *> *members) {
    struct stat info;
    if (fstat(directory, &info) || !S_ISDIR(info.st_mode) || info.st_uid != geteuid() ||
        (info.st_mode & 07777) != 0755) return NO;
    int copy = dup(directory);
    DIR *stream = copy < 0 ? NULL : fdopendir(copy);
    if (!stream) { if (copy >= 0) close(copy); return NO; }
    NSMutableSet *names = [NSMutableSet set];
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(stream))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
        if (!name || !members[name]) { closedir(stream); return NO; }
        [names addObject:name];
    }
    int failed = errno;
    closedir(stream);
    if (failed || ![names isEqualToSet:[NSSet setWithArray:members.allKeys]]) return NO;
    for (NSString *name in members) {
        mode_t wanted = [executables() containsObject:name] ? 0755 : 0644;
        if (fstatat(directory, name.UTF8String, &info, AT_SYMLINK_NOFOLLOW) ||
            !S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != geteuid() ||
            (info.st_mode & 07777) != wanted) return NO;
        NSData *bytes = read_member(directory, name.UTF8String, HGMaxArchive);
        if (!bytes || ![bytes isEqualToData:members[name]]) return NO;
    }
    return YES;
}

static BOOL write_staged_member(int directory, NSString *name, NSData *bytes) {
    int fd = openat(directory, name.UTF8String,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    size_t offset = 0;
    BOOL valid = YES;
    while (offset < bytes.length) {
        ssize_t n = write(fd, (const char *)bytes.bytes + offset, bytes.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { valid = NO; break; }
        offset += (size_t)n;
    }
    mode_t mode = [executables() containsObject:name] ? 0755 : 0644;
    if (valid && (fchmod(fd, mode) || fsync(fd))) valid = NO;
    if (close(fd)) valid = NO;
    return valid;
}

int hg_guest_payload_stage_directory(const char *resources,
                                     const HGGuestPayloadIdentity *identity,
                                     int parent_fd, char **report) {
    if (report) *report = NULL;
    @autoreleasepool {
        NSString *failure = @"stage-parent";
        NSDictionary *members = nil, *validated = nil;
        BOOL published = NO, reused = NO, cleanupComplete = YES, success = NO;
        char staging[64] = {0};
        int stage = -1;
        int parent = fcntl(parent_fd, F_DUPFD_CLOEXEC, 3);
        struct stat parentInfo, stageInfo;
        memset(&stageInfo, 0, sizeof(stageInfo));
        if (parent < 0 || fstat(parent, &parentInfo) || !S_ISDIR(parentInfo.st_mode) ||
            parentInfo.st_uid != geteuid() || (parentInfo.st_mode & 0022)) goto done;
        {
            int source = resources ? open(resources, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
            if (source < 0 || !identity) { if (source >= 0) close(source); failure = @"resource-directory"; goto done; }
            validated = validate(source, identity, &failure, &members);
            close(source);
            if (!validated) goto done;
        }
        {
            int existing = openat(parent, identity->payload_id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (existing >= 0) {
                reused = staged_members_match(existing, members);
                close(existing);
                if (!reused) { failure = @"existing-payload-conflict"; goto done; }
                published = YES;
                if (fsync(parent)) { failure = @"stage-parent-sync"; goto done; }
                success = YES;
                goto done;
            }
            if (errno != ENOENT) { failure = @"existing-payload-conflict"; goto done; }
        }
        for (unsigned int attempt = 0; attempt < 8; attempt++) {
            uint64_t random;
            arc4random_buf(&random, sizeof(random));
            snprintf(staging, sizeof(staging), ".henge-stage-%016llx", (unsigned long long)random);
            if (!mkdirat(parent, staging, 0700)) break;
            if (errno != EEXIST || attempt == 7) { staging[0] = 0; failure = @"stage-create"; goto done; }
        }
        stage = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (stage < 0 || fstat(stage, &stageInfo)) { failure = @"stage-open"; goto done; }
        for (NSString *name in [[members allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if (!write_staged_member(stage, name, members[name])) { failure = @"stage-write"; goto done; }
        }
        if (fchmod(stage, 0755) || !staged_members_match(stage, members) || fsync(stage)) {
            failure = @"stage-readback-or-sync"; goto done;
        }
        {
            struct stat named;
            if (fstatat(parent, staging, &named, AT_SYMLINK_NOFOLLOW) ||
                named.st_dev != stageInfo.st_dev || named.st_ino != stageInfo.st_ino) {
                failure = @"stage-identity-changed"; goto done;
            }
        }
        if (renameatx_np(parent, staging, parent, identity->payload_id, RENAME_EXCL)) {
            failure = @"stage-publish-conflict"; goto done;
        }
        published = YES;
        staging[0] = 0;
        if (fsync(parent)) { failure = @"stage-parent-sync"; goto done; }
        success = YES;
    done:
        if (staging[0]) {
            struct stat named;
            if (stage >= 0 && !fstatat(parent, staging, &named, AT_SYMLINK_NOFOLLOW) &&
                named.st_dev == stageInfo.st_dev && named.st_ino == stageInfo.st_ino) {
                for (NSString *name in members) {
                    if (unlinkat(stage, name.UTF8String, 0) && errno != ENOENT) cleanupComplete = NO;
                }
                if (unlinkat(parent, staging, AT_REMOVEDIR)) cleanupComplete = NO;
            } else cleanupComplete = NO;
        }
        if (stage >= 0) close(stage);
        if (parent >= 0) close(parent);
        NSMutableDictionary *result = [@{@"schema": @1, @"operation": @"stage-payload-v1",
            @"payload_staged": @(success), @"published": @(published), @"already_present": @(reused),
            @"cleanup_complete": @(cleanupComplete), @"activation_performed": @NO} mutableCopy];
        if (validated) [result addEntriesFromDictionary:validated];
        if (!success) result[@"error"] = failure;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if (report && json) *report = strndup(json.bytes, json.length);
        return success ? 0 : 65;
    }
}

int hg_guest_payload_verify_executable(const HGGuestPayloadIdentity *identity, char **report) {
    char path[PATH_MAX], canonical[PATH_MAX];
    uint32_t length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) || !realpath(path, canonical))
        return hg_guest_payload_verify_directory(NULL, identity, report);
    char *slash = strrchr(canonical, '/');
    if (!slash) return hg_guest_payload_verify_directory(NULL, identity, report);
    *slash = 0;
    return hg_guest_payload_verify_directory(canonical, identity, report);
}
