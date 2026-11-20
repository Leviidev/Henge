#ifndef HENGE_LINUX_OSCACHECONTROL_H
#define HENGE_LINUX_OSCACHECONTROL_H
#include <stddef.h>
static inline void sys_icache_invalidate(void *start, size_t len) { __builtin___clear_cache((char *)start, (char *)start + len); }
#endif
