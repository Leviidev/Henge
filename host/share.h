#ifndef HENGEVM_SHARE_H
#define HENGEVM_SHARE_H

#include <stddef.h>

/* What the Mac and the device share: a folder and the clipboard (see share.c). The guest reaches this
   at HV_SHARE_ADDR, port 80, which the network hands to the Unix socket. Returns 0, or -1 if the socket
   can't be made. agent is the gzipped helper that runs inside macOS, served to the guest; it may be NULL. */
#define HV_SHARE_ADDR "10.0.2.4"
int hv_share_start(const char *folder, const char *socket_path, const char *agent);

/* The device's clipboard, for the guest to pick up. */
void hv_share_set_clipboard(const char *text);
unsigned long hv_share_publish_clipboard(const char *text);
int hv_share_clipboard_ready(void);
int hv_share_clipboard_delivered(unsigned long seq);
/* What the guest last copied, once: a malloc'd string, or NULL if nothing is new. */
char *hv_share_take_clipboard(void);
/* Called after a guest update, outside the clipboard lock, on the server thread.
   Must return promptly; UI clients enqueue work. Setting a handler also signals
   an already pending value. A captured static handler may finish after removal. */
void hv_share_set_clipboard_notify(void (*notify)(void));
/* Seconds since the helper in macOS was last heard from, or -1 if it never has been. */
long hv_share_agent_seen(void);

#endif
