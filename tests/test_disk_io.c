/* Portable syscall-injection tests for PR #31's large transfer loops. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "machine.h"
#include "disk.h"

int hv_knob[HV_K_COUNT];
static unsigned calls;
static int write_fd = 123;
static uint64_t done;
static int failure_mode;
static unsigned char *buffer;
#define TOTAL (272u << 20)

static ssize_t transfer(void *buf, size_t count, off_t offset, int write) {
    calls++;
    assert(count > 0 && count <= (128u << 20));
    assert((unsigned char *)buf == buffer + done);
    assert((uint64_t)offset == 4096 + done);
    if (failure_mode == 1) return 0;
    if (failure_mode == 2) { errno = EIO; return -1; }
    /* Retry EINTR both before progress and after a short transfer. */
    if (calls == 1 || calls == 3) { errno = EINTR; return -1; }
    size_t n = calls == 2 ? count / 2 : count;
    if (!write) memset(buf, 0x5a, n);
    else assert(((unsigned char *)buf)[0] == 0x5a && ((unsigned char *)buf)[n - 1] == 0x5a);
    done += n;
    return (ssize_t)n;
}
ssize_t __wrap_pread(int fd, void *buf, size_t count, off_t offset) {
    assert(fd == 123); return transfer(buf, count, offset, 0);
}
ssize_t __wrap_pwrite(int fd, const void *buf, size_t count, off_t offset) {
    assert(fd == write_fd); return transfer((void *)buf, count, offset, 1);
}
int main(void) {
    buffer = malloc(TOTAL);
    assert(buffer);
    HvDisk disk = {.fd = 123, .wfd = -1, .offset = 4096, .size = TOTAL};
    assert(hv_disk_read(&disk, 0, buffer, TOTAL) == 0);
    assert(calls == 5 && done == TOTAL);
    assert(buffer[0] == 0x5a && buffer[TOTAL - 1] == 0x5a);
    calls = 0; done = 0;
    assert(hv_disk_write(&disk, 0, buffer, TOTAL) == 0);
    assert(calls == 5 && done == TOTAL);
    calls = 0; done = 0;
    disk.wfd = write_fd = 77;
    assert(hv_disk_write(&disk, 0, buffer, TOTAL) == 0);
    assert(calls == 5 && done == TOTAL);
    disk.wfd = -1; write_fd = 123;
    calls = 0;
    assert(hv_disk_read(&disk, TOTAL - 1, buffer, 2) == -1);
    assert(hv_disk_write(&disk, UINT64_MAX, buffer, 1) == -1);
    disk.readonly = 1;
    assert(hv_disk_write(&disk, 0, buffer, 1) == -1);
    disk.readonly = 0;
    assert(calls == 0);
    assert(hv_disk_read(&disk, TOTAL, buffer, 0) == 0);
    assert(hv_disk_write(&disk, TOTAL, buffer, 0) == 0);
    assert(calls == 0);
    for (failure_mode = 1; failure_mode <= 2; failure_mode++) {
        calls = 0; done = 0;
        assert(hv_disk_read(&disk, 0, buffer, 8) == -1);
        assert(calls == 1);
        calls = 0;
        assert(hv_disk_write(&disk, 0, buffer, 8) == -1);
        assert(calls == 1);
    }
    free(buffer);
    puts("disk chunking, EINTR, partial transfers, bounds and error tests passed");
}
