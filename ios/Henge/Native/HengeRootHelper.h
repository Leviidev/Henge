#ifndef HENGE_ROOT_HELPER_H
#define HENGE_ROOT_HELPER_H
/* Synchronous, bounded read-only probe; call away from the UI thread.
 * Returns malloc-owned JSON on success, NULL otherwise. No guest is accessed. */
char *henge_root_helper_probe(void);
/* Internal read-only image inspection through fixed child FD 3. Call off the
 * UI thread with a machine-owned disk path. The lease closes before return;
 * an installer must acquire its own lease and revalidate before using it. */
char *henge_root_helper_inspect_disk(const char *path);
#endif
