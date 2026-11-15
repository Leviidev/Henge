#!/usr/bin/env python3
"""Production parser fuzz/bounds checks under address and undefined sanitizers."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = r'''#include "display_snapshot.h"
#include <assert.h>
#include <stdlib.h>
int main(void) {
    unsigned char data[sizeof(HvDisplaySnapshot) + 128] = {0};
    HvDisplaySnapshot d = {.version=HV_DISPLAY_SNAPSHOT_VERSION,.ports=2}, out;
    size_t bytes[2];
    memcpy(data, &d, sizeof d);
    assert(!hv_display_snapshot_parse(data, sizeof d, &out, bytes));
    for (size_t n=0;n<sizeof d;n++) assert(hv_display_snapshot_parse(data,n,&out,bytes));
    d.port[0]=(HvDisplaySnapshotPort){.width=4,.height=4,.stride=16};
    d.port[1]=d.port[0]; memcpy(data,&d,sizeof d);
    assert(!hv_display_snapshot_parse(data,sizeof data,&out,bytes));
    for (size_t i=0;i<sizeof d;i++) {
        unsigned char saved=data[i];
        for (unsigned value=0;value<256;value++) {
            data[i]=value;
            for (size_t n=0;n<=sizeof data;n++)
                (void)hv_display_snapshot_parse(data,n,&out,bytes);
        }
        data[i]=saved;
    }
    d.port[1].stride=UINT32_MAX; memcpy(data,&d,sizeof d);
    assert(hv_display_snapshot_parse(data,sizeof data,&out,bytes));
    return 0;
}'''
with tempfile.TemporaryDirectory() as tmp:
    c=pathlib.Path(tmp)/'parser.c'; c.write_text(source)
    binary=pathlib.Path(tmp)/'parser'
    subprocess.run(['cc','-O1','-g','-fsanitize=address,undefined','-Wall','-Wextra','-Werror',
                    '-I'+str(root/'devices'),str(c),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
print('Display snapshot parser: two ports, all header mutations and truncations passed ASan/UBSan')
