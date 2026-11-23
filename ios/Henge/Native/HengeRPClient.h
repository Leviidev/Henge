/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Pairing as the computer, for the Apple Vision Pro (ios/rppairing-client, libhenge_rpclient.a, built by
   ios/scripts/build_rpclient.sh). Keep in step with ios/rppairing-client/src/lib.rs. */
#pragma once
#include <stddef.h>
#include <stdint.h>

/* Returns the code the device shows, allocated with malloc (strdup), or NULL to cancel. May block. */
typedef char *(*HengeRPClientCodeProvider)(void *context);

/* Pairs with the device's _remotepairing-manual-pairing._tcp service at host:port. Blocks. 0 paired (the
   pairing file, an XML plist, in *out_bytes, free with henge_rpclient_bytes_free), 1 cancelled, -1 failed
   (*error set, free with henge_rpclient_string_free). */
int32_t henge_rpclient_pair(const char *host, uint16_t port, const char *host_name,
                            HengeRPClientCodeProvider provider, void *context,
                            uint8_t **out_bytes, size_t *out_len, char **error);
void henge_rpclient_bytes_free(uint8_t *bytes, size_t len);
void henge_rpclient_string_free(char *string);
