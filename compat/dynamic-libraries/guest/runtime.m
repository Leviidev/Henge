#include "adapter.m"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#include <math.h>
static void HGMaybeInstall(id<MTLDevice> d) {
  if (!d)
    return;
  BOOL supportedClass =
      [NSStringFromClass([d class]) isEqual:@"AppleParavirtDevice"] &&
      !d.supportsDynamicLibraries &&
      NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14;
#ifdef HG_ALLOW_NATIVE_TESTING
  supportedClass |= getenv("HENGE_DYNAMIC_TEST_DEVICE") != NULL;
#endif
  if (!supportedClass)
    return;
  if (!HGLoadConfiguration())
    return;
  HGInstall(d, HGRoot);
}
typedef id<MTLDevice> (*HGCreateFn)(void) __attribute__((ns_returns_retained));
typedef NSArray<id<MTLDevice>> *(*HGDevicesFn)(void)
    __attribute__((ns_returns_retained));
// dyld excludes the replacement image's own symbol bindings from interposition.
// dlsym(RTLD_NEXT) can return an interposed address and recurse; direct calls
// retain the original binding for this image.
static id<MTLDevice> __attribute__((ns_returns_retained)) HGCreateDevice(void) {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  HGMaybeInstall(d);
  return d;
}
static NSArray<id<MTLDevice>> *__attribute__((ns_returns_retained))
HGCopyDevices(void) {
  NSArray *devices = MTLCopyAllDevices();
  for (id d in devices)
    HGMaybeInstall(d);
  return devices;
}
__attribute__((used)) static struct {
  const void *replacement;
  const void *original;
} HGInterpose[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)HGCreateDevice, (const void *)MTLCreateSystemDefaultDevice},
    {(const void *)HGCopyDevices, (const void *)MTLCopyAllDevices},
};
