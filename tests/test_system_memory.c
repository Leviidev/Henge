#include "system_memory.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(!hv_system_memory_read(NULL));
    host_t host=mach_host_self();
    mach_port_urefs_t before=0,after=0;
    vm_size_t page=0;
    assert(host_page_size(host,&page)==KERN_SUCCESS && page);
    assert(mach_port_get_refs(mach_task_self(),host,MACH_PORT_RIGHT_SEND,&before)==KERN_SUCCESS);
    HvSystemMemory info;
    for(unsigned i=0;i<8;i++){
        assert(hv_system_memory_read(&info));
        assert(info.free%page==0 && info.wired%page==0 && info.compressed%page==0);
    }
    assert(mach_port_get_refs(mach_task_self(),host,MACH_PORT_RIGHT_SEND,&after)==KERN_SUCCESS && before==after);
    mach_port_deallocate(mach_task_self(),host);
    puts("PASS system memory: real HOST_VM_INFO64 reads, page units, null handling and bounded Mach send-right lifetime; raw categories are not allocatable headroom");
}
