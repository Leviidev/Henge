#include "../devices/gpu_record_support.h"
#include <assert.h>
#include <stdio.h>
#include "../devices/gpu_pass_options.h"
#include "../devices/gpu_reject_stats.h"
int main(void){
    HvGpuRejectStats stats={0};
    HvGpuReject rejected={HV_GPU_TAG,1,219,0,0,4};
    hv_gpu_reject_note(&stats,rejected);rejected.available=8;hv_gpu_reject_note(&stats,rejected);
    rejected.type=0;hv_gpu_reject_note(&stats,rejected);
    rejected.reason=HV_GPU_PAYLOAD;hv_gpu_reject_note(&stats,rejected);
    assert(stats.used==3&&!stats.overflow);
    const HvGpuRejectBucket *top=hv_gpu_reject_top(&stats,0);
    assert(top->count==2&&top->type==1&&top->min_bytes==4&&top->max_bytes==8);
    assert(hv_gpu_reject_top(&stats,1)->reason==HV_GPU_TAG);
    assert(hv_gpu_reject_top(&stats,2)->reason==HV_GPU_PAYLOAD);
    assert(!hv_gpu_reject_top(&stats,3));
    for(unsigned tag=1000;tag<1100;tag++){rejected.tag=tag;hv_gpu_reject_note(&stats,rejected);}
    assert(stats.used==HV_GPU_REJECT_BUCKETS&&stats.overflow==71);
    rejected=(HvGpuReject){HV_GPU_TAG,1,219,0,0,0};hv_gpu_reject_note(&stats,rejected);
    assert(hv_gpu_reject_top(&stats,0)->count==3&&hv_gpu_reject_top(&stats,0)->min_bytes==0);
    uint32_t draw[]={12,0,107,12,0};
    assert(hv_metal4_segment_supported(draw,sizeof draw));
    draw[0]=100;assert(hv_metal4_segment_supported(draw,sizeof draw)); /* outer descriptor bounds replay, like legacy */
    draw[0]=sizeof draw;assert(hv_metal4_segment_supported(draw,sizeof draw)); /* inclusive envelope */
    draw[0]=12;
    draw[2]=24;assert(!hv_metal4_segment_supported(draw,sizeof draw)); /* missing stages */
    draw[2]=107;draw[3]=0;assert(!hv_metal4_segment_supported(draw,sizeof draw));
    draw[3]=13;assert(!hv_metal4_segment_supported(draw,sizeof draw));
    assert(!hv_metal4_segment_supported(draw,7));
    assert(hv_metal4_tag_supported(4,460));
    assert(!hv_metal4_tag_supported(0,13));
    assert(hv_metal4_tag_supported(1,212));
    assert(hv_metal4_tag_supported(1,219));
    assert(!hv_metal4_tag_supported(0,219));
    assert(!hv_metal4_tag_supported(2,219));
    uint32_t ignored_compute[]={12,1,219,12,0};
    assert(hv_metal4_segment_supported(ignored_compute,sizeof ignored_compute));
    ignored_compute[0]=11;ignored_compute[3]=11;
    assert(!hv_metal4_segment_supported(ignored_compute,sizeof ignored_compute));
    uint32_t unknown_layout[]={16,1,219,16,0,0};
    assert(!hv_metal4_segment_supported(unknown_layout,sizeof unknown_layout));
    unknown_layout[2]=220;
    assert(!hv_metal4_segment_supported(unknown_layout,sizeof unknown_layout));
    assert(hv_metal4_tag_supported(2,316));
    uint32_t protected[]={0,5,0,0,8,1,214,8};
    assert(hv_metal4_segment_supported(protected,sizeof protected));
    HvGpuReject why={0};
    uint32_t query[]={28,4,460,28,0,0,0,0,0};
    assert(hv_metal4_segment_check(query,sizeof query,&why));
    query[2]=499;assert(!hv_metal4_segment_check(query,sizeof query,&why));
    assert(why.reason==HV_GPU_TAG&&why.type==4&&why.tag==499&&why.offset==8);
    uint32_t shortdraw[]={14,0,1,14,0,0};
    assert(!hv_metal4_segment_supported(shortdraw,22)); /* primitive/start/count needs all8 bytes */
    uint32_t padded[]={24,0,107,12,0,0,0,0};
    assert(hv_metal4_segment_supported(padded,sizeof padded));
    padded[7]=1;assert(!hv_metal4_segment_supported(padded,sizeof padded));
    const uint32_t tags[]={102,103,105,106,120,121};
    HvGpuPassOptions options={0},same={0};
    for(unsigned i=0;i<6;i++) {
        uint32_t n=tags[i]==103?12:8;
        uint32_t record[]={n+8,0,tags[i],n+8,1,0,0};
        assert(hv_metal4_segment_supported(record,16+n));
        if(tags[i]==103||tags[i]==106||tags[i]==121)
            assert(hv_gpu_pass_option(&options,tags[i],record+4,n));
    }
    same=options;assert(hv_gpu_pass_options_equal(&options,&same));
    same.values[8]=0;assert(!hv_gpu_pass_options_equal(&options,&same));
    uint8_t fuzz[160];uint32_t seed=0x17438789;
    for(unsigned j=0;j<30000;j++) {
        for(unsigned k=0;k<sizeof fuzz;k++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;fuzz[k]=(uint8_t)seed;}
        (void)hv_metal4_segment_check(fuzz,j%sizeof fuzz,&why);
    }
    puts("PASS Metal4 stream compatibility: shared bounded headers, inclusive lengths, protected segments, queries, store options, indirect draws and malformed/fuzzed rejection");
}
