#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Prototype C ABI. Borrowed arrays stay valid for this synchronous call.
// Row 0 is the consumer, followed by at most 16 declared dependency libraries.
// Preloaded bits identify explicitly preloaded rows; row 0 cannot be preloaded.
// No filesystem reads or implicit dependency discovery. malloc outputs are owned
// by the caller. A nonzero return never supplies executable substitute bytes.
int HGStatelessMetallibClose(const void *const *bytes, const size_t *sizes,
    const char *const *origins, size_t count, uint32_t preloaded, const char *entry,
    int retargetIOS, void **output, size_t *outputSize, char **error);
// Additional compile dependencies must have declared absolute install names
// and occur in the explicit preload set, matching the guest adapter protocol.
int HGStatelessMetallibCloseRequired(const void *const *bytes, const size_t *sizes,
    const char *const *origins, size_t count, uint32_t preloaded, const char *entry,
    const char *const *required, size_t requiredCount, int retargetIOS,
    void **output, size_t *outputSize, char **error);
#ifdef __cplusplus
}
#endif
