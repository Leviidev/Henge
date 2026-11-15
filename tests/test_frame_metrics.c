#include "frame_metrics.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void){
 struct HvFrameMetrics m={.generation=2};
 hv_frame_record(&m,1,1);assert(!m.frames);
 for(int i=0;i<=1000;i++)hv_frame_record(&m,2,1+i/60.0);
 assert(m.frames==1001 && m.intervals==1000);
 assert(fabs(1000*m.intervals/m.total_ms-60)<0.001);
 assert(hv_frame_percentile(&m,95)>=16.66 && hv_frame_percentile(&m,95)<=16.92);
 assert(hv_frame_low1(&m)>59 && hv_frame_low1(&m)<=60);
 hv_frame_record(&m,2,m.last);hv_frame_record(&m,2,NAN);assert(m.invalid==2);
 hv_frame_record(&m,2,m.last+2);assert(m.overflow==1 && hv_frame_low1(&m)==0);
 memset(&m,0,sizeof m);assert(hv_frame_percentile(&m,99)==0);
 hv_frame_record(&m,0,1);hv_frame_record(&m,0,3);
 assert(m.overflow==1 && hv_frame_percentile(&m,95)==0 && hv_frame_percentile(&m,100)==0);
 /* Static desktop gaps do not masquerade as queued-frame latency. */
 memset(&m,0,sizeof m);m.generation=3;
 hv_frame_submission(&m,2,1,1.01);assert(!m.latency_samples);
 hv_frame_submission(&m,3,1,1.01);hv_frame_record(&m,3,1.01);
 hv_frame_submission(&m,3,201,201.01);hv_frame_record(&m,3,201.01);
 assert(m.overflow==1 && m.latency_samples==2 && fabs(m.latency_total_ms-20)<0.001);
 assert(hv_frame_bins_percentile(m.latency_bins,m.latency_samples,95)<=10.25);
 hv_frame_submission(&m,3,202,0);assert(m.not_presented==1 && m.latency_samples==2);
 hv_frame_submission(&m,3,NAN,202);hv_frame_submission(&m,3,202,201);
 hv_frame_submission(&m,3,0,202);assert(m.latency_invalid==3);
 hv_frame_submission(&m,3,203,205);assert(m.latency_overflow==1 && m.latency_max_ms==2000);
 assert(hv_frame_bins_percentile(m.latency_bins,m.latency_samples,100)==0);
 puts("frame telemetry: known 60Hz intervals, quantiles, tail estimate, epochs, nonfinite/reversed time and overflow passed");
 puts("PASS submit-to-present timing: idle gaps excluded; missing presentation, stale epoch, clock errors and overflow kept explicit");
}
