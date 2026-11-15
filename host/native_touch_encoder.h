#ifndef HENGE_NATIVE_TOUCH_ENCODER_H
#define HENGE_NATIVE_TOUCH_ENCODER_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
/* Exact five-slot USB format used by the entitlement-free guest companion.
   The caller owns validation, locking, scheduling and transport. */
typedef struct HvTouchFrame { size_t count; uint8_t ids[5]; double x[5], y[5]; } HvTouchFrame;
typedef struct HvTouchSlot {
    uint8_t id, down, published;
    double x,y,lifted;
} HvTouchSlot;
typedef struct HvTouchEncoder {
    HvTouchSlot slots[5];
    uint8_t last[32];
    int has_last;
    double deadline;
} HvTouchEncoder;
static inline int hv_touch_member(const HvTouchFrame *f, unsigned id) {
    for(size_t i=0;i<f->count;i++)if(f->ids[i]==id)return (int)i;
    return -1;
}
static inline unsigned hv_touch_down_mask(const HvTouchEncoder *e) {
    unsigned mask=0;for(unsigned i=0;i<5;i++)if(e->slots[i].id&&e->slots[i].down)mask|=1u<<i;return mask;
}
static inline void hv_touch_encoder_cancel(HvTouchEncoder *e) {
    for(unsigned i=0;i<5;i++) {
        HvTouchSlot *s=&e->slots[i];
        if(!s->published)memset(s,0,sizeof *s);
        else if(s->down){s->down=0;s->lifted=0;}
    }
}
/* Consumed is set only when the complete desired membership was installed.
   Motion may update immediately during a membership settling interval. */
static inline int hv_touch_encoder_step(HvTouchEncoder *e,const HvTouchFrame *f,double now,
                                        int *consumed,uint8_t report[32]) {
    *consumed=0;
    unsigned before=0;
    if(e->has_last)for(unsigned i=0;i<5;i++) {
        unsigned at=1+6*i,id=e->last[at+1];
        if(e->last[at]==3&&id>=1&&id<=5)before|=1u<<(id-1);
    }
    for(unsigned i=0;i<5;i++) {
        HvTouchSlot *s=&e->slots[i];
        if(s->id&&!s->down&&s->lifted>0&&now-s->lifted>=.06)memset(s,0,sizeof *s);
    }
    if(f) {
        unsigned down=0;int same=1;
        for(unsigned i=0;i<5;i++)if(e->slots[i].id&&e->slots[i].down) {
            down++;if(hv_touch_member(f,e->slots[i].id)<0)same=0;
        }
        same=same&&down==f->count;
        if(same||now>=e->deadline) {
            unsigned fresh=0,free_slots=0;int retired=0;
            for(unsigned i=0;i<5;i++)if(!e->slots[i].id)free_slots++;
            for(size_t j=0;j<f->count;j++) {
                int found=0;
                for(unsigned i=0;i<5;i++)if(e->slots[i].id==f->ids[j]) {
                    found=1;if(!e->slots[i].down)retired=1;
                }
                if(!found)fresh++;
            }
            {
                for(unsigned i=0;i<5;i++)if(e->slots[i].id&&e->slots[i].down) {
                    int j=hv_touch_member(f,e->slots[i].id);
                    if(j<0){e->slots[i].down=0;e->slots[i].lifted=0;}
                    else {e->slots[i].x=f->x[j];e->slots[i].y=f->y[j];}
                }
                if(!retired&&fresh<=free_slots) {
                for(size_t j=0;j<f->count;j++) {
                    int found=0;for(unsigned i=0;i<5;i++)if(e->slots[i].id==f->ids[j])found=1;
                    if(!found)for(unsigned i=0;i<5;i++)if(!e->slots[i].id) {
                        e->slots[i]=(HvTouchSlot){.id=f->ids[j],.down=1,.x=f->x[j],.y=f->y[j]};break;
                    }
                }
                *consumed=1;
                }
            }
        }
    }
    memset(report,0,32);report[0]=1;
    unsigned occupied=0;
    for(unsigned i=0;i<5;i++)if(e->slots[i].id) {
        HvTouchSlot *s=&e->slots[i];unsigned at=1+6*occupied++;
        uint16_t x=(uint16_t)(s->x*32767+.5),y=(uint16_t)(s->y*32767+.5);
        report[at]=s->down?3:2;report[at+1]=(uint8_t)(i+1);
        report[at+2]=(uint8_t)x;report[at+3]=(uint8_t)(x>>8);
        report[at+4]=(uint8_t)y;report[at+5]=(uint8_t)(y>>8);
    }
    report[31]=(uint8_t)occupied;
    if(e->has_last&&!memcmp(e->last,report,32))return 0;
    unsigned after=hv_touch_down_mask(e);
    if(before!=after || (!e->has_last&&after))e->deadline=now+.06;
    for(unsigned i=0;i<5;i++)if(e->slots[i].id) {
        if(e->slots[i].down)e->slots[i].published=1;
        else if(!e->slots[i].lifted)e->slots[i].lifted=now;
    }
    memcpy(e->last,report,32);e->has_last=1;return 1;
}
static inline double hv_touch_encoder_due(const HvTouchEncoder *e,int pending,double now) {
    double retired=0;
    for(unsigned i=0;i<5;i++)if(e->slots[i].id&&!e->slots[i].down&&e->slots[i].lifted>0) {
        double t=e->slots[i].lifted+.06;
        if(!retired||t<retired)retired=t;
    }
    double due=pending?(e->deadline>now?e->deadline:(retired>now?retired:now)):0;
    if(retired&&(!due||retired<due))due=retired;
    return due;
}
#endif
