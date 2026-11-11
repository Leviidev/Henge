#ifndef HG_GUEST_CODE_IDENTITY_H
#define HG_GUEST_CODE_IDENTITY_H
/* Bind a kernel-reported 20-byte CDHash to a held read-only executable file.
 * Bounded thin little-endian 64-bit MH_EXECUTE, SHA-256/256-truncated CodeDirectory
 * and 4/16 KiB page profile. Verifies every covered file page as well as the
 * selected CodeDirectory hash. Does not attest process UID, entitlements,
 * dependencies, external resource seals or sandbox rights. */
int hg_guest_code_identity_matches(int executable_fd,const unsigned char cdhash[20],const char **error);
#endif
