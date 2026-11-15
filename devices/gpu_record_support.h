#ifndef HENGE_GPU_RECORD_SUPPORT_H
#define HENGE_GPU_RECORD_SUPPORT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "gpu_stream.h"
#include "pvg_store_action.h"
/* Closed set, checked before creating a Metal4 encoder. Patch/tile
 * draws, indirect command buffers and opaque queries retain their original
 * complete replay until the corresponding semantics have a tested mapping. */
static inline bool hv_metal4_tag_supported(unsigned type,uint32_t tag) {
    if(type==0){
        if(tag<=11 || tag==16 || tag==17 || tag==24 || tag==25 || tag==26 || tag==27 || tag==28 || tag==29 || tag==30 || tag==34 || tag==35 || tag==36)return true;
        switch(tag){
        case 101:case 102:case 103:case 104:case 105:case 106:case 107:case 108:case 109:
        case 110:case 111:case 112:case 113:case 114:case 115:case 116:case 117:case 118:case 119:
        case 120:case 121:case 124:case 125:case 126:case 127:case 128:case 129:case 130:case 131:case 134:case 135:case 137:
        case 165:case 166:return true;
        default:return false;
        }
    }
    if(type==1){switch(tag){case 200:case 202:case 203:case 204:case 206:case 207:case 208:case 211:case 212:case 213:case 214:case 215:case 216:case 219:return true;default:return false;}}
    if(type==2){switch(tag){case 300:case 301:case 302:case 303:case 306:case 307:case 308:case 309:case 310:case 311:case 314:case 315:case 316:case 317:return true;default:return false;}}
    /* These are CPU-side capability/address queries, also executed by the
       existing info handler. They need no legacy GPU encoder. */
    if(type==4){switch(tag){case 450:case 451:case 457:case 460:case 461:case 462:case 463:case 464:case 466:case 467:case 468:case 469:return true;default:return false;}}
    return false;
}
static inline bool hv_metal4_payload_supported(unsigned type,uint32_t tag,const uint8_t *p,size_t n){
    /* macOS emits this four-byte record among ordinary compute commands.
       The reference compute decoder deliberately consumes it without making
       an encoder call. Match that behaviour; it needs no Metal4 adapter and
       must not force otherwise representable work through a queue bridge.
       Do not generalise this to other unknown tags or payload layouts. */
    if(type==1&&tag==219)return n==4;
    size_t need=0;
    if(type==0){switch(tag){
        case 0:need=20;break;case 1:need=8;break;case 2:need=26;break;case 3:need=8;break;
        case 4:need=34;break;case 5:need=10;break;case 6:need=24;break;case 7:need=12;break;
        case 8:need=32;break;case 9:need=14;break;case 10:case 28:need=48;break;case 11:case 29:need=18;break;
        case 16:need=16;break;case 17:need=28;break;
        case 24:case 25:need=8;break;case 26:need=76;break;case 30:case 34:case 35:case 36:need=4;break;
        case 101:need=16;break;case 102:case 105:case 120:need=8;break;case 104:case 107:case 109:case 115:case 116:case 124:need=4;break;
        case 108:need=12;break;case 111:case 126:need=12;break;case 117:need=32;break;
        case 118:need=32;break;case 119:need=8;break;case 130:case 131:need=48;break;case 166:need=20;break;
        default:break;
    }}else if(type==1){switch(tag){case 200:case 202:need=48;break;case 207:need=12;break;case 208:case 212:case 213:need=4;break;case 211:need=12;break;case 216:need=8;break;default:break;}}
    else if(type==2){switch(tag){case 300:case 303:need=88;break;case 301:need=32;break;case 302:need=86;break;case 307:case 316:case 317:need=4;break;case 306:need=21;break;default:break;}}
    else if(type==4)need=tag==451?44:tag==469?52:tag==460?20:16;
    if(n<need)return false;
    if(type==0&&(tag==102||tag==103||tag==105||tag==106||tag==120||tag==121)) {
        HvStoreAction action;if(!hv_pvg_decode_store_action(tag,p,n,&action))return false;
    }
    bool buffers=(type==0&&(tag==110||tag==125||tag==165))||(type==1&&tag==203);
    bool textures=(type==0&&(tag==114||tag==129))||(type==1&&tag==206);
    bool samplers=(type==0&&(tag==112||tag==113||tag==127||tag==128))||(type==1&&tag==204);
    if(buffers||textures||samplers){
        if(n<8)return false;
        uint32_t index,count;memcpy(&index,p,4);memcpy(&count,p+4,4);
        uint32_t limit=buffers?31:textures?128:16,step=buffers?(tag==165?20:12):(tag==113||tag==128)?12:4;
        if(index>limit||count>limit-index||n-8<(size_t)count*step)return false;
    }
    if(type==0&&(tag==27||tag==134||tag==135||tag==137)){
        size_t head=tag==134?4:8;if(n<head)return false;
        uint32_t count;memcpy(&count,p,4);if(count>256||n-head<(size_t)count*4)return false;
    }
    return true;
}
static inline bool hv_metal4_segment_check(const void *data,size_t size,HvGpuReject *why) {
    HvGpuSegment s;if(!hv_gpu_segment(data,size,&s,why))return false;
    if(s.type>2&&s.type!=4)return hv_gpu_reject(why,HV_GPU_ENCODER,s.type,0,0,0,0);
    size_t at=s.start;HvGpuRecord r;int status;
    while((status=hv_gpu_next(&s,&at,&r,why))>0) {
        if(!hv_metal4_tag_supported(s.type,r.tag))return hv_gpu_reject(why,HV_GPU_TAG,s.type,r.tag,r.offset,0,r.size);
        if(!hv_metal4_payload_supported(s.type,r.tag,r.bytes,r.size))return hv_gpu_reject(why,HV_GPU_PAYLOAD,s.type,r.tag,r.offset,0,r.size);
    }
    if(status<0)return false;
    return true;
}
static inline bool hv_metal4_segment_supported(const void *data,size_t size) {
    return hv_metal4_segment_check(data,size,NULL);
}
#endif
