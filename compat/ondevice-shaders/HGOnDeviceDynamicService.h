#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Synchronous private guest-network handler. Never call from the UI, renderer
// worker or compiler queue. Returns an HTTP status; malloc response belongs to
// the caller. No filesystem access, guest-memory access or Metal calls occur.
int HGOnDeviceDynamicService(const char *method, const char *resource,
    const void *body, size_t length, void **response, size_t *responseLength);
#ifdef __OBJC__
#import <dispatch/dispatch.h>
// Ordinary and dynamic LLVM work must use this single process-wide queue.
dispatch_queue_t HGOnDeviceCompilerQueue(void);
#endif
#ifdef __cplusplus
}
#endif
