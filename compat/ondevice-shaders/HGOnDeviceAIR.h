#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Owned malloc outputs. Returns0 on success. Caller frees all nonnull outputs.
// Isolated reviewed AIR2.6 executable profile. No network, subprocess or Apple compiler.
int HGOnDeviceAIRConvert(const void *bytes,size_t length,int retargetIOS,int applyGL,
 void **output,size_t *outputLength,char **profileJSON,char **errorMessage);
#ifdef __cplusplus
}
#endif
