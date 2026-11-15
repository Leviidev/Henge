#ifndef HENGE_INPUT_RING_H
#define HENGE_INPUT_RING_H
#include <stdint.h>
#define HV_VINPUT_RING 4096
/* Queue operations run under the device mutex. Keep button states authoritative
   even if a stalled guest exhausts the bounded motion/event ring. */
typedef struct HvInputEvent { uint16_t type, code; uint32_t value; } HvInputEvent;
static inline int hv_input_button_owner(uint8_t owners[3],unsigned button,unsigned source,int down,int *state) {
    if(button>2 || source>7)return 0;
    uint8_t before=owners[button],bit=(uint8_t)(1u<<source);
    owners[button]=down?before|bit:before&~bit;
    *state=owners[button]!=0;
    return !!before!=*state;
}
static inline void hv_input_enqueue(HvInputEvent *ring, uint32_t *head, uint32_t *tail,
                                    uint8_t *buttons, uint64_t *dropped, int mouse,
                                    uint16_t type, uint16_t code, int32_t value) {
    if (mouse && type == 1 && code >= 0x110 && code <= 0x112) {
        uint8_t bit = (uint8_t)(1u << (code-0x110));
        *buttons = value ? *buttons | bit : *buttons & ~bit;
    }
    if (*tail - *head == HV_VINPUT_RING) {
        if (mouse) {
            /* Drop stale motion as a unit, then reconcile all buttons. A lost
               up cannot keep the guest dragging indefinitely. New motion follows
               the reconciliation frame; relative movement cannot change buttons. */
            *dropped += *tail - *head;
            *head = *tail;
            for (unsigned b=0; b<3; b++) {
                ring[(*tail)++ % HV_VINPUT_RING] = (HvInputEvent){1, (uint16_t)(0x110+b), !!(*buttons & (1u<<b))};
            }
            ring[(*tail)++ % HV_VINPUT_RING] = (HvInputEvent){0,0,0};
            if (type == 1 || type == 0) return;
        } else { (*head)++; (*dropped)++; }
    }
    ring[(*tail)++ % HV_VINPUT_RING] = (HvInputEvent){type,code,(uint32_t)value};
}
#endif
