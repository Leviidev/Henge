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
/* Read-only parent-app attestation diagnostic. No path/image FD is accepted,
 * and a successful report is not transferable write authority. A future
 * mutation operation must reattest its own live caller and target rights. */
char *henge_root_helper_attest_caller(void);
/* Qualifies live caller + explicit app-opened read/write capability for one
 * machine-owned disk. Passes only fixed FDs 3/4, no path/UID argument. The
 * helper inspects and leases but NEVER writes/attaches/mounts the source.
 * Returned JSON is diagnostic only; all authority/leases expire on return.
 * Future provisioning must retain/revalidate these within its own operation. */
char *henge_root_helper_check_write_authority(const char *path);
#endif
