#define _POSIX_C_SOURCE 200809L
#include "trace_gate.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>

int main(void) {
    char path[] = "/tmp/henge-trace-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);
    HvTraceGate gate = {0};
    assert(hv_trace_file_enabled(&gate, path, 0));
    assert(unlink(path) == 0);
    for (int i = 1; i < 2000; i++)
        assert(hv_trace_file_enabled(&gate, path, i / 2000.0));
    assert(gate.probes == 1 && gate.cached == 1999);
    assert(!hv_trace_file_enabled(&gate, path, 1.0));
    fd = open(path, O_CREAT | O_WRONLY, 0600);
    assert(fd >= 0);
    close(fd);
    assert(!hv_trace_file_enabled(&gate, path, 1.5));
    assert(hv_trace_file_enabled(&gate, path, 2.0));
    assert(unlink(path) == 0);
    assert(!hv_trace_file_enabled(&gate, path, 100.0));
    assert(gate.probes == 4);
    HvTraceGate none = {0};
    assert(!hv_trace_file_enabled(&none, NULL, 0) && !none.probes);
    puts("GPU trace flag: 2000 batches -> 1 filesystem probe; live enable/disable passed");
}
