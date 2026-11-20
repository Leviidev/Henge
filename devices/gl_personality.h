#pragma once
/* macOS's OpenGL finds its renderer by reading IOGLBundleName from the GPU driver object, which takes it from
   the driver's IOKit personality. AppleParavirtGPU's personality has none, so OpenGL apps fall back to software.
   This adds the key to that personality in the kernelcache's prelink XML while it sits in guest RAM, before
   the kernel reads it. The XML keeps its exact length: the personality's indentation makes room. */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { HV_GL_PATCHED = 1, HV_GL_PRESENT = 0, HV_GL_NOT_FOUND = -1, HV_GL_NO_ROOM = -2 };

static const char hv_gl_match[] = "<string>paravirtualizedgraphics,gpu</string>";
static const char hv_gl_entry[] = "<key>IOGLBundleName</key><string>AppleMetalOpenGLRenderer</string>";

static int hv_gl_space(uint8_t c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

/* buf/len: the personality dict, from its "<dict>" through its "</dict>". */
static int hv_gl_patch_dict(uint8_t *buf, size_t len) {
    if (memmem(buf, len, "IOGLBundleName", 14)) return HV_GL_PRESENT;
    uint8_t out[4096];
    size_t entry = sizeof hv_gl_entry - 1, n = 0;
    if (len > sizeof out || len < 6) return HV_GL_NO_ROOM;
    memcpy(out, buf, 6); /* "<dict>" */
    n = 6;
    if (n + entry > len) return HV_GL_NO_ROOM;
    memcpy(out + n, hv_gl_entry, entry);
    n += entry;
    for (size_t i = 6; i < len; i++) {
        /* Whitespace between a tag's '>' and the next '<' carries no meaning in a plist. */
        if (hv_gl_space(buf[i])) {
            size_t j = i;
            while (j < len && hv_gl_space(buf[j])) j++;
            if (buf[i - 1] == '>' && j < len && buf[j] == '<') { i = j - 1; continue; }
        }
        if (n >= len) return HV_GL_NO_ROOM;
        out[n++] = buf[i];
    }
    /* Pad before the closing "</dict>" to the original length. */
    size_t close = 7, pad = len - n;
    memmove(out + n - close + pad, out + n - close, close);
    memset(out + n - close, '\n', pad);
    memcpy(buf, out, len);
    return HV_GL_PATCHED;
}

/* Searches all of buf for the AppleParavirtGPU personality and patches it. */
static int hv_gl_personality_patch(uint8_t *buf, size_t len) {
    uint8_t *m = memmem(buf, len, hv_gl_match, sizeof hv_gl_match - 1);
    if (!m) return HV_GL_NOT_FOUND;
    /* The personality's own <dict> is the last one opened before the match, and holds no nested dict. */
    uint8_t *open = NULL;
    for (uint8_t *p = m; p > buf && m - p < 4096; p--)
        if (!memcmp(p, "<dict>", 6)) { open = p; break; }
    if (!open) return HV_GL_NOT_FOUND;
    uint8_t *close = memmem(m, (size_t)(buf + len - m), "</dict>", 7);
    if (!close || close - open > 4000) return HV_GL_NOT_FOUND;
    if (!memmem(open, (size_t)(close - open), "<string>AppleParavirtGPU</string>", 33)) return HV_GL_NOT_FOUND;
    return hv_gl_patch_dict(open, (size_t)(close + 7 - open));
}
