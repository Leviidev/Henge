#ifndef HENGE_FRAME_PACING_H
#define HENGE_FRAME_PACING_H
/* Deadlines use monotonic seconds. No periodic timer when there is no work. */
typedef struct HvFramePacing { double next; unsigned long long coalesced; } HvFramePacing;
static inline int hv_pacing_fps(int selected, int thermal, int protect) {
    int cap = selected == 30 || selected == 60 ? selected : 0;
    int heat = protect && thermal >= 2 ? (thermal >= 3 ? 20 : 30) : 0;
    return heat && (!cap || heat < cap) ? heat : cap;
}
static inline int hv_pacing_power_fps(int selected,int thermal,int protect,int power_aware,int low_power) {
    int cap=hv_pacing_fps(selected,thermal,protect);
    return power_aware && low_power && (!cap || cap>60) ? 60 : cap;
}
static inline double hv_pacing_delay(HvFramePacing *p, double now, int fps) {
    if (!fps) { p->next = 0; return 0; }
    return p->next > now ? p->next - now : 0;
}
static inline void hv_pacing_presented(HvFramePacing *p, double now, int fps) {
    p->next = fps ? now + 1.0 / fps : 0;
}
#endif
