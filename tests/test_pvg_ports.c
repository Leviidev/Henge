/* Exercise production command decoding and state-page routing without a VM
   image. Dead stripping excludes the renderer/device paths not used here. */
#include "../devices/pvg_lite.c"
#include <assert.h>
static _Alignas(0x4000) uint8_t memory[0x14000];
static int irqs;
static int metal_submits;
HvPvgMetal *hv_pvg_metal_create(HvPvgLite *p){(void)p;return (HvPvgMetal *)(uintptr_t)1;}
void hv_pvg_metal_set_layer(HvPvgMetal *p,void *layer){(void)p;(void)layer;}
void hv_pvg_metal_unmap(HvPvgMetal *p,uint32_t mapping){(void)p;(void)mapping;}
void hv_pvg_metal_submit(HvPvgMetal *m,HvPvgLite *p,uint32_t ch,uint32_t *cmd,uint32_t len){
    (void)m;(void)p;assert(ch==1 && len==12 && cmd[2]==123);metal_submits++;free(cmd);
}
void *hv_phys_ptr(HvMachine *m,uint64_t pa,uint64_t n){
    (void)m;return pa<=sizeof memory && n<=sizeof memory-pa ? memory+pa : NULL;
}
void hv_gicv3_pend(HvGic *g,int id){(void)g;(void)id;irqs++;}
static uint32_t word(uint32_t page,uint32_t off){uint32_t n;memcpy(&n,memory+page+off,4);return n;}
int main(void){
    HvPvgLite *p=calloc(1,sizeof *p);assert(p);
    p->display_count=2;
    p->displays[0].mode=(HvPvgDisplayMode){2752,2064,265,199,120};p->displays[0].connected=1;
    p->displays[1].mode=(HvPvgDisplayMode){1920,1350,160,113,60};p->displays[1].connected=1;
    HvPvgDisplayMode saved_mode;assert(!hv_pvg_lite_port_mode(p,1,&saved_mode));
    assert(saved_mode.width==1920 && saved_mode.hz==60);assert(hv_pvg_lite_port_mode(p,2,&saved_mode)==-1);
    uint32_t a[]={1,20,0,0,1},b[]={1,20,0,1,2};
    hv_pvg_lite_command(p,a,sizeof a);hv_pvg_lite_command(p,b,sizeof b);
    assert(word(0x4000,0x210)==(2064u<<16|2752));assert(word(0x8000,0x210)==(1350u<<16|1920));
    uint16_t primary_port,secondary_port;
    memcpy(&primary_port,memory+0x4000+0x12,2);memcpy(&secondary_port,memory+0x8000+0x12,2);
    assert(primary_port==0 && secondary_port==1); // Apple's line-314 startup precondition
    assert(gfx_read(p,0x122c,4)==2);
    uint32_t ack[]={2,20,0,1,1};hv_pvg_lite_command(p,ack,sizeof ack);
    assert(word(0x8000,0xfc0)==2 && word(0x4000,0xfc0)==1);
    uint32_t swap[]={8,28,0,1,0,1234,0}; /* legal short swap: no gamma fields */
    hv_pvg_lite_command(p,swap,sizeof swap);
    assert(word(0x8000,0xfb0)==1234 && word(0x4000,0xfb0)==0);
    swap[3]=0;swap[5]=4321;hv_pvg_lite_command(p,swap,sizeof swap);
    assert(word(0x4000,0xfb0)==4321 && word(0x8000,0xfb0)==1234);
    uint8_t primary[0x4000];memcpy(primary,memory+0x4000,sizeof primary);
    swap[3]=UINT32_MAX;hv_pvg_lite_command(p,swap,sizeof swap);
    hv_pvg_lite_apply_link_connected(p,0);
    assert(irqs==1 && gfx_read(p,0x1014,4)==2 && gfx_read(p,0x1014,4)==0);
    assert(!memcmp(primary,memory+0x4000,sizeof primary));assert(word(0x8000,0x208)==0);
    ack[4]=1;hv_pvg_lite_command(p,ack,sizeof ack);assert(word(0x8000,0xfc0)==1);
    ack[4]=2;hv_pvg_lite_command(p,ack,sizeof ack);assert(word(0x8000,0xfc0)==0);
    hv_pvg_lite_apply_link_connected(p,1);assert(word(0x8000,0x200)==3 && irqs==2);
    p->display_count=1;assert(gfx_read(p,0x122c,4)==1);
    b[4]=3;hv_pvg_lite_command(p,b,sizeof b);assert(p->displays[1].page==0x8000);
    // Real foreground PVG ring decoding with only the host Metal driver replaced.
    // Commands publish exactly once without a separate Runner gate.
    memset(memory,0,sizeof memory);p->layer_lock=(os_unfair_lock)OS_UNFAIR_LOCK_INIT;
    p->regs[(0x101c-0x1000)/4]=1; /* root records at 0x4000 */
    p->regs[(0x1030-0x1000)/4]=2; /* completion stamps at 0x8000 */
    p->regs[(0x1004-0x1000)/4]=0x2000;
    p->regs[(0x1010-0x1000)/4]=0x1000;
    p->regs[(0x1008-0x1000)/4]=12;
    uint32_t *rootCommand=(void *)(memory+0x9000);rootCommand[1]=12;rootCommand[2]=987;
    uint32_t *rec=(void *)(memory+0x4400);rec[0]=12;rec[4]=3;
    uint32_t *table=(void *)(memory+0xc000);table[0]=4;
    uint32_t *command=(void *)(memory+0x10000);command[0]=0x20;command[1]=12;command[2]=123;
    p->io_regs[0x18/8]=9;
    int beforeIRQs=irqs;
    gfx_read(p,0x100c,4);do_channel(p,1);do_mapper(p);
    hv_pvg_lite_poll(p);
    assert(rec[1]==12 && metal_submits==1 && !p->chan_pending && p->io_regs[0x20/8]==9);
    assert(p->root_rp==12 && word(0x8000,0)==987);
    int afterIRQs=irqs;assert(afterIRQs>=beforeIRQs);
    hv_pvg_lite_poll(p);assert(metal_submits==1 && irqs==afterIRQs);
    free(p);puts("PASS production PVG commands: two ports, short swaps, invalid ports, independent ack/mapping, hotplug IRQ, disabled-port guard");return 0;
}
