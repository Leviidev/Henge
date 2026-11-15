#ifndef HENGE_FRAME_METRICS_H
#define HENGE_FRAME_METRICS_H
#include <stdint.h>
#include <math.h>
/* Opt-in host-presentation intervals, not a game's simulation/render FPS. */
#define HV_FRAME_BINS 4096
#define HV_FRAME_BIN_MS 0.25
struct HvFrameMetrics {
    uint64_t generation, frames, intervals, invalid, overflow;
    double first, last, total_ms, max_ms;
    uint64_t bins[HV_FRAME_BINS];
    uint64_t latency_samples, latency_invalid, not_presented, latency_overflow;
    double latency_total_ms, latency_max_ms;
    uint64_t latency_bins[HV_FRAME_BINS];
};
/* Same Core Animation media clock at submission and presentation. Unlike
   inter-frame cadence, this does not count an idle desktop's no-work gap.
   This measures queued drawable latency, NOT guest input/render latency. */
static inline void hv_frame_submission(struct HvFrameMetrics *m,uint64_t generation,double submitted,double presented) {
    if(generation!=m->generation)return;
    if(presented==0){m->not_presented++;return;}
    if(!isfinite(submitted)||!isfinite(presented)||submitted<=0||presented<submitted){m->latency_invalid++;return;}
    double ms=(presented-submitted)*1000;
    if(!isfinite(ms)){m->latency_invalid++;return;}
    unsigned bin=ms/HV_FRAME_BIN_MS>=HV_FRAME_BINS-1?HV_FRAME_BINS-1:(unsigned)(ms/HV_FRAME_BIN_MS);
    if(bin==HV_FRAME_BINS-1)m->latency_overflow++;
    m->latency_bins[bin]++;m->latency_samples++;m->latency_total_ms+=ms;
    if(ms>m->latency_max_ms)m->latency_max_ms=ms;
}
static inline void hv_frame_record(struct HvFrameMetrics *m,uint64_t generation,double t) {
    if(generation!=m->generation)return;
    if(!isfinite(t)||t<=0||(m->last && t<=m->last)){m->invalid++;return;}
    if(!m->frames)m->first=t;
    if(m->last){double ms=(t-m->last)*1000;m->total_ms+=ms;if(ms>m->max_ms)m->max_ms=ms;
        unsigned bin=ms/HV_FRAME_BIN_MS>=HV_FRAME_BINS-1?HV_FRAME_BINS-1:(unsigned)(ms/HV_FRAME_BIN_MS);
        if(ms/HV_FRAME_BIN_MS>=HV_FRAME_BINS-1)m->overflow++;
        m->bins[bin]++;m->intervals++;}
    m->last=t;m->frames++;
}
static inline double hv_frame_bins_percentile(const uint64_t *bins,uint64_t count,unsigned percent) {
    if(!count || percent<1 || percent>100)return 0;
    uint64_t want=(count*percent+99)/100,seen=0;
    for(unsigned i=0;i<HV_FRAME_BINS;i++){seen+=bins[i];if(seen>=want)return i==HV_FRAME_BINS-1 ? 0 : (i+1)*HV_FRAME_BIN_MS;}
    return 0;
}
static inline double hv_frame_percentile(const struct HvFrameMetrics *m,unsigned percent) {
    return hv_frame_bins_percentile(m->bins,m->intervals,percent);
}
static inline double hv_frame_low1(const struct HvFrameMetrics *m) {
    uint64_t want=(m->intervals+99)/100,left=want;double sum=0;
    if(!want || m->overflow)return 0; // don't fabricate an overflow-bin tail
    for(int i=HV_FRAME_BINS-1;i>=0&&left;i--){uint64_t take=m->bins[i]<left?m->bins[i]:left;sum+=take*(i+1)*HV_FRAME_BIN_MS;left-=take;}
    return sum?1000*want/sum:0;
}
#endif
