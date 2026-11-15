#include "translate.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static HvMachine machine;
static unsigned hot(unsigned mode,const uint32_t *code,unsigned n) {
    hv_knob[HV_K_GROUPS]=(int)mode;
    HvBlock block={.va=0x100000,.pa=0x100000};
    uint64_t before=machine.stats.words_inline;
    assert(!hv_translate_emit(&machine,&block,code,n));
    unsigned words=(unsigned)(machine.stats.words_inline-before);
    printf("register-groups: mode=%u guest=%u inline_words=%u hot_allocation=%u total_words=%u\n",mode,n,words,hv_translate_last_words(),hv_translate_pending_words());
    return words;
}
int main(void) {
    assert(!hv_machine_init(&machine,4<<20));machine.chain=1;machine.stats_interval=1;
    const uint32_t stack_frame[]={0xa9bc7bfd,0xa9014ff4,0xa90257f6,0xa9414ff4,0xa94257f6,0xa8c47bfd,0xd65f03c0};
    unsigned frame_plain=hot(0,stack_frame,7),frame_grouped=hot(2,stack_frame,7);
    printf("writeback-groups: enabled=%d plain=%u grouped=%u\n",hv_translate_writeback_groups(),frame_plain,frame_grouped);
    assert(frame_grouped<frame_plain);
    const uint32_t stream[]={0xf9400001,0xf9400402,0xf9400803,0xf9400c04,0xd65f03c0};
    unsigned plain=hot(0,stream,5),selected=hot(2,stream,5);
    assert(selected+10<plain); /* actual emitter, not a copied cost model */
    const uint32_t clobber[]={0xf9400001,0xf9400402,0x910004c6,0xf9400803,0xf9400c04,0xd65f03c0};
    assert(hot(2,clobber,6)+8<hot(0,clobber,6)); /* two independent validated pairs survive the scratch clobber */
    const uint32_t stack_adjust[]={0xf94003e1,0xf94007e2,0xd10043ff,0xf94003e3,0xf94007e4,0xd65f03c0};
    assert(hot(2,stack_adjust,6)+8<hot(0,stack_adjust,6)); /* SP origin changes split, rather than poison, stack groups */
    const uint32_t alternating[]={0xf9400001,0xf9400402,0xf9400183,0xf9400584,0xf9400803,0xf9400c04,0xd65f03c0};
    assert(hot(2,alternating,7)+10<hot(0,alternating,7)); /* field groups on distinct base registers */
    assert(hot(2,stream+1,4)+6<hot(0,stream+1,4)); /* three-field objects also reuse the translation */
    assert(hot(2,stream+2,3)<hot(0,stream+2,3)); /* two fields share one validated lookup */
    const uint32_t interleaved[]={0xf9400181,0xf94001a2,0xf9400583,0xf94005a4,0xf9400985,0xf94009a7,0xd65f03c0};
    if(hv_translate_interleaved_groups())assert(hot(2,interleaved,7)+10<hot(0,interleaved,7));
    else assert(hot(2,interleaved,7)==hot(0,interleaved,7));
    hv_knob[HV_K_GROUP_MIN]=3;
    assert(hot(0,stream+2,3)==hot(2,stream+2,3));
    hv_knob[HV_K_GROUP_MIN]=2;
    const uint32_t barrier[]={0xf9400001,0xf9400402,0xf9400803,0xd5033bbf,
                              0xf9400001,0xf9400402,0xf9400803,0xd65f03c0};
    assert(hot(2,barrier,8)+12<hot(0,barrier,8)); /* independent groups on both sides of DMB */
    hv_machine_free(&machine);
    puts("PASS register groups: real inline-path reduction; two-field reuse, scratch clobber safety and three-access reference policy");
}
