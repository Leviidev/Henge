#include "env_flag.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(!hv_env_flag_value(NULL));
    for (unsigned i = 0; i < 4; i++) {
        const char *off[] = {"0", "false", "NO", "Off"};
        assert(!hv_env_flag_value(off[i]));
    }
    const char *on[] = {"", "1", "true", "YES", "on"};
    for (unsigned i = 0; i < sizeof on / sizeof *on; i++) assert(hv_env_flag_value(on[i]));
    puts("PASS explicit false and legacy presence flags");
}
