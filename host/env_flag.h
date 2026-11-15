#ifndef HENGE_ENV_FLAG_H
#define HENGE_ENV_FLAG_H
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Presence-only flags historically accept an empty value. Explicit false
   values must still work in henge-env.txt, whose overrides are applied last. */
static inline int hv_env_flag_value(const char *value) {
    return value && strcmp(value, "0") && strcasecmp(value, "false") &&
           strcasecmp(value, "no") && strcasecmp(value, "off");
}
static inline int hv_env_flag(const char *name) { return hv_env_flag_value(getenv(name)); }
#endif
