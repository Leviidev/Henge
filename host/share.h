#ifndef HENGEVM_SHARE_H
#define HENGEVM_SHARE_H

#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

/* What the Mac and the device share: a folder and the clipboard (see share.c). The guest reaches this
   at HV_SHARE_ADDR, port 80, which the network hands to the Unix socket. Returns 0, or -1 if the socket
   can't be made. agent is the gzipped helper that runs inside macOS, served to the guest; it may be NULL. */
#define HV_SHARE_ADDR "10.0.2.4"
int hv_share_start(const char *folder, const char *socket_path, const char *agent);
/* Optional embedded shader service on the same private guest-only transport.
   The handler returns HTTP status and a malloc-owned JSON body. One request's
   body/handler is admitted at a time, with a 24 MiB body limit. */
typedef int (*HvShareShaderService)(const char *, const char *, const void *, size_t, void **, size_t *);
void hv_share_set_shader_service(HvShareShaderService service);

/* The device's clipboard, for the guest to pick up. */
void hv_share_set_clipboard(const char *text);
/* What the guest last copied, once: a malloc'd string, or NULL if nothing is new. */
char *hv_share_take_clipboard(void);
/* Seconds since the helper in macOS was last heard from, or -1 if it never has been. */
long hv_share_agent_seen(void);

#ifdef __cplusplus
}
#endif
#endif
