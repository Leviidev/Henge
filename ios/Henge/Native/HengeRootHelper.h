#ifndef HENGE_ROOT_HELPER_H
#define HENGE_ROOT_HELPER_H
/* Synchronous, bounded read-only probe; call away from the UI thread.
 * Returns malloc-owned JSON on success, NULL otherwise. No guest is accessed. */
char *henge_root_helper_probe(void);
#endif
