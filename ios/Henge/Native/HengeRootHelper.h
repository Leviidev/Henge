#ifndef HENGE_ROOT_HELPER_H
#define HENGE_ROOT_HELPER_H
/* Synchronous, bounded read-only probe; call away from the UI thread.
 * Returns malloc-owned JSON on success, NULL otherwise. No guest is accessed. */
char *henge_root_helper_probe(void);
/* Internal read-only image inspection through fixed child FD 3. Call off the
 * UI thread with a machine-owned disk path. The lease closes before return;
 * an installer must acquire its own lease and revalidate before using it. */
char *henge_root_helper_inspect_disk(const char *path);
/* Bounded startup discard-only recovery in a fixed helper-private root
 * namespace. No caller/guest path or image FD is accepted. Returns malloc-owned
 * JSON; incomplete/retained cleanup is reported rather than force-cleaned.
 * Call off the UI thread. Does not open the original disk or mount a copy. */
char *henge_root_helper_recover_workspaces(void);
#endif
