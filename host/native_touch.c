#include "native_touch.h"
#include "native_touch_encoder.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define QUEUE_SIZE 64
#define MAX_CONTACTS 5
typedef HvTouchFrame Frame;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static Frame queue[QUEUE_SIZE], current;
static size_t queued;
static uint32_t epoch = 1;
static int enabled, status, host_encoded, cancel_pending, sender_expired;
static HvTouchEncoder encoder;
static double last_sender, last_helper, started;
static HvNativeTouchUSB usb;
static uint64_t accepted_frames,rejected_frames,usb_reports,usb_failures,cancellations;
static size_t peak_queued;
static int setup_phase,helper_stalled,neutral_required;
static double last_helper_poll;
static uint64_t helper_polls;
static uint64_t helper_stalls,helper_recoveries;
static double encode_locked(void);
#ifdef HV_NATIVE_TOUCH_TEST_CLOCK
static double test_time;
void hv_native_touch_test_time(double value) { test_time=value; }
#endif
static int same_contacts(const Frame *a, const Frame *b) {
    return a->count == b->count && !memcmp(a->ids,b->ids,a->count);
}
static double now(void) {
#ifdef HV_NATIVE_TOUCH_TEST_CLOCK
return test_time;
#endif
struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void reset_locked(void) {
    if (usb.connect) usb.connect(usb.context, 0);
    if (++epoch == 0) epoch = 1;
    queued = 0; memset(&current, 0, sizeof current);
    host_encoded = cancel_pending = sender_expired = 0; memset(&encoder,0,sizeof encoder);
    setup_phase=helper_stalled=neutral_required=0;
    started = last_sender = now(); last_helper = 0;
    status = enabled ? HV_TOUCH_WAITING : HV_TOUCH_OFF;
    pthread_cond_broadcast(&changed);
}
static void expire_locked(void) {
    double t = now();
    if(enabled && host_encoded && status==HV_TOUCH_READY &&
       (current.count || queued || hv_touch_down_mask(&encoder)) &&
       t-last_sender>.7 && !sender_expired) {
        // A UI stall releases contacts, not the mapped USB display. The UIKit
        // surface fences resting contacts when its heartbeat resumes.
        sender_expired=1;cancel_pending=1;queued=0;memset(&current,0,sizeof current);
        fprintf(stderr,"native-touch-state: epoch=%u UI sender stalled; cancelling contacts, mapping retained\n",epoch);
        pthread_cond_broadcast(&changed);
    }
    if(enabled && host_encoded && status==HV_TOUCH_READY && t-last_helper>2.5 && !helper_stalled) {
        helper_stalled=1;neutral_required=1;helper_stalls++;
        cancel_pending=1;queued=0;memset(&current,0,sizeof current);
        encode_locked();
        fprintf(stderr,"native-touch-state: epoch=%u helper stalled; contacts neutralized, mapping retained for bounded recovery\n",epoch);
        pthread_cond_broadcast(&changed);
    }
    double helper_timeout=host_encoded?30:.7;
    if (enabled && ((status == HV_TOUCH_READY && (t-last_helper > helper_timeout || (!host_encoded && t-last_sender > .7))) ||
                    (status == HV_TOUCH_WAITING && (t-(last_helper>started?last_helper:started)>(usb.connect ? 30 : 5) || t-started>30)))) {
        fprintf(stderr,"native-touch-state: epoch=%u timeout status=%d setup_phase=%d helper_age_ms=%.0f sender_age_ms=%.0f\n",epoch,status,setup_phase,last_helper?(t-last_helper)*1000:-1,(t-last_sender)*1000);
        enabled = 0; reset_locked(); status = HV_TOUCH_TIMEOUT;
    }
}
/* Called only under mutex. Host encoding uses the existing helper long-poll
   worker to finish required lift intervals; there is no new idle timer/thread. */
static double encode_locked(void) {
    if(!host_encoded || !enabled || status!=HV_TOUCH_READY)return 0;
    double t=now();
    if(cancel_pending && t>=encoder.deadline) {
        hv_touch_encoder_cancel(&encoder);cancel_pending=0;
    }
    for(unsigned step=0; !cancel_pending && step<=QUEUE_SIZE; step++) {
        uint8_t report[32];int consumed=0;
        int emitted=hv_touch_encoder_step(&encoder,queued?&queue[0]:NULL,t,&consumed,report);
        if(consumed){current=queue[0];memmove(queue,queue+1,(--queued)*sizeof(Frame));}
        if(emitted)usb_reports++;
        if(emitted && (!usb.report || !usb.report(usb.context,report))) {
            usb_failures++;
            enabled=0;reset_locked();status=HV_TOUCH_TIMEOUT;return 0;
        }
        if(!consumed || !queued)break;
    }
    return cancel_pending?encoder.deadline:hv_touch_encoder_due(&encoder,queued!=0,t);
}
void hv_native_touch_cancel(uint32_t generation) {
    pthread_mutex_lock(&mutex);expire_locked();
    if(!enabled || generation!=epoch){pthread_mutex_unlock(&mutex);return;}
    cancellations++;
    queued=0;memset(&current,0,sizeof current);
    if(host_encoded) {
        cancel_pending=1;encode_locked();
    } else {
        // Legacy helpers retain the original neutral frame transport.
        queue[queued++]=(Frame){0};
    }
    pthread_cond_broadcast(&changed);pthread_mutex_unlock(&mutex);
}
uint32_t hv_native_touch_enable(int on) {
    pthread_mutex_lock(&mutex);
    if (enabled != !!on || (!on && status != HV_TOUCH_OFF)) { enabled = !!on; reset_locked(); }
    uint32_t value = epoch; pthread_mutex_unlock(&mutex); return value;
}
uint32_t hv_native_touch_reset(void) {
    pthread_mutex_lock(&mutex); reset_locked(); uint32_t value = epoch;
    pthread_mutex_unlock(&mutex); return value;
}
uint32_t hv_native_touch_epoch(void) {
    pthread_mutex_lock(&mutex); uint32_t value = epoch; pthread_mutex_unlock(&mutex); return value;
}
int hv_native_touch_status(void) {
    pthread_mutex_lock(&mutex); expire_locked(); encode_locked(); int value = helper_stalled && status==HV_TOUCH_READY ? HV_TOUCH_STALLED : status; pthread_mutex_unlock(&mutex); return value;
}
int hv_native_touch_helper_alive(void) {
    pthread_mutex_lock(&mutex);
    double age=now()-last_helper_poll;
    int alive=helper_polls&&age>=0&&age<2.5;
    pthread_mutex_unlock(&mutex);return alive;
}
int hv_native_touch_direct_mapping(void) {
    pthread_mutex_lock(&mutex);expire_locked();
    int value=enabled && host_encoded && usb.connected && usb.connected(usb.context);
    pthread_mutex_unlock(&mutex);return value;
}
int hv_native_touch_submit(uint32_t generation, const uint8_t *ids, const double *x, const double *y, size_t count) {
    if (count > MAX_CONTACTS || (count && (!ids || !x || !y))) return 0;
    Frame frame = {.count = count};
    for (size_t i = 0; i < count; i++) {
        if (!ids[i] || ids[i] > 127 || !isfinite(x[i]) || !isfinite(y[i]) || x[i] < 0 || x[i] > 1 || y[i] < 0 || y[i] > 1) return 0;
        for (size_t j = 0; j < i; j++) if (ids[j] == ids[i]) return 0;
        frame.ids[i] = ids[i]; frame.x[i] = x[i]; frame.y[i] = y[i];
    }
    pthread_mutex_lock(&mutex); expire_locked();
    if (!enabled || status != HV_TOUCH_READY || generation != epoch) { rejected_frames++;pthread_mutex_unlock(&mutex); return 0; }
    last_sender = now();sender_expired=0;
    if(neutral_required) {
        if(!count)neutral_required=0;
        else { rejected_frames++;pthread_mutex_unlock(&mutex);return 0; }
    }
    if(helper_stalled) { rejected_frames++;pthread_mutex_unlock(&mutex);return 0; }
    accepted_frames++;
    if(host_encoded && usb.keepalive)usb.keepalive(usb.context);
    // Keep the sender watchdog alive without waking the helper for an unchanged idle frame.
    if (!count && !queued && !current.count) {
        pthread_mutex_unlock(&mutex);
        return 1;
    }
    /* Only coalesce motion: preserve every change in contact membership, including short taps. */
    const Frame *before=queued>1?&queue[queued-2]:&current;
    if (queued && same_contacts(&queue[queued-1],&frame) && same_contacts(before,&queue[queued-1])) queue[queued-1] = frame;
    else if (queued < QUEUE_SIZE) queue[queued++] = frame;
    else { enabled = 0; reset_locked(); status = HV_TOUCH_DEVICE; pthread_mutex_unlock(&mutex); return 0; }
    if(queued>peak_queued)peak_queued=queued;
    encode_locked();
    pthread_cond_signal(&changed); pthread_mutex_unlock(&mutex); return 1;
}
void hv_native_touch_report(uint32_t generation, int value) {
    pthread_mutex_lock(&mutex); expire_locked();
    // Setup progress does not declare readiness, disconnect USB or downgrade
    // an already-ready service. A bounded slow IOKit attach can stay alive.
    if(enabled && generation==epoch && value==HV_TOUCH_WAITING) {
        if(status==HV_TOUCH_WAITING)last_helper=now();
        pthread_mutex_unlock(&mutex);return;
    }
    if (enabled && generation == epoch && value >= HV_TOUCH_READY && value <= HV_TOUCH_DEVICE) {
        if(status!=value)fprintf(stderr,"native-touch-state: epoch=%u status=%d->%d setup_phase=%d direct_usb=%d\n",epoch,status,value,setup_phase,host_encoded);
        if(value==HV_TOUCH_READY && helper_stalled) {
            helper_stalled=0;helper_recoveries++;
            fprintf(stderr,"native-touch-state: epoch=%u helper recovered; mapping reused, new contacts require a neutral boundary\n",epoch);
        }
        last_helper = now(); if (status == HV_TOUCH_WAITING) last_sender = last_helper; status = value;
        if (value != HV_TOUCH_READY) {
            enabled = 0; queued = 0; memset(&current, 0, sizeof current);
            if (usb.connect) usb.connect(usb.context, 0);
        } else if (usb.keepalive) usb.keepalive(usb.context);
    }
    pthread_mutex_unlock(&mutex);
}
void hv_native_touch_progress(uint32_t generation,int phase) {
    pthread_mutex_lock(&mutex);expire_locked();
    if(enabled && generation==epoch && status==HV_TOUCH_WAITING && phase>=0 && phase<=6) {
        last_helper=now();
        if(setup_phase!=phase)fprintf(stderr,"native-touch-setup: epoch=%u phase=%d (1 detach,2 attach,3 IOHID mapping,4 event association,5 screen discovery,6 direct USB)\n",epoch,phase);
        setup_phase=phase;
    }
    pthread_mutex_unlock(&mutex);
}
void hv_native_touch_failure(uint32_t generation,int phase,int code) {
    pthread_mutex_lock(&mutex);
    if(enabled && generation==epoch)fprintf(stderr,"native-touch-guest-error: epoch=%u phase=%d code=%d (bounded guest setup error, no input contents)\n",generation,phase,code);
    pthread_mutex_unlock(&mutex);
    hv_native_touch_report(generation,HV_TOUCH_DEVICE);
}
void hv_native_touch_log(void) {
    pthread_mutex_lock(&mutex);
    double t=now();
    fprintf(stderr,"native-touch-metrics: epoch=%u enabled=%d status=%d direct_usb=%d setup_phase=%d queued=%zu peak=%zu frames=%llu rejected=%llu reports=%llu failed=%llu cancels=%llu helper_age_ms=%.0f sender_age_ms=%.0f\n",epoch,enabled,status,host_encoded,setup_phase,queued,peak_queued,(unsigned long long)accepted_frames,(unsigned long long)rejected_frames,(unsigned long long)usb_reports,(unsigned long long)usb_failures,(unsigned long long)cancellations,last_helper?(t-last_helper)*1000:-1,(t-last_sender)*1000);
    fprintf(stderr,"native-touch-recovery: stalls=%llu recovered=%llu stalled=%d neutral_required=%d\n",(unsigned long long)helper_stalls,(unsigned long long)helper_recoveries,helper_stalled,neutral_required);
    fprintf(stderr,"native-touch-companion: polls=%llu last_poll_age_ms=%.0f (USB companion traffic, distinct from clipboard/sharing presence)\n",(unsigned long long)helper_polls,helper_polls?(t-last_helper_poll)*1000:-1);
    pthread_mutex_unlock(&mutex);
}
size_t hv_native_touch_next(char *json, size_t capacity) {
    if (capacity < 1024) return 0;
    pthread_mutex_lock(&mutex);helper_polls++;last_helper_poll=now();expire_locked();
    double due=encode_locked();
    if (!queued || host_encoded) {
        double delay=.25;
        if(due>0) {double remaining=due-now();if(remaining<delay)delay=remaining>0?remaining:.001;}
        struct timespec until; clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += (long)(delay*1e9);
        if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
        pthread_cond_timedwait(&changed, &mutex, &until); expire_locked();encode_locked();
    }
    if (queued && !host_encoded) { current = queue[0]; memmove(queue, queue+1, (--queued)*sizeof(Frame)); }
    size_t n = (size_t)snprintf(json, capacity, "{\"version\":1,\"epoch\":%u,\"enabled\":%s,\"usb\":%s,\"contacts\":[", epoch, enabled ? "true" : "false", usb.connect ? "true" : "false");
    for (size_t i = 0; !host_encoded && i < current.count; i++) n += (size_t)snprintf(json+n, capacity-n,
        "%s{\"id\":%u,\"x\":%.9f,\"y\":%.9f}", i ? "," : "", current.ids[i], current.x[i], current.y[i]);
    n += (size_t)snprintf(json+n, capacity-n, "]}");
    pthread_mutex_unlock(&mutex); return n;
}

void hv_native_touch_set_usb(const HvNativeTouchUSB *transport) {
    pthread_mutex_lock(&mutex);
    enabled = 0; reset_locked();
    usb = transport ? *transport : (HvNativeTouchUSB){0};
    pthread_mutex_unlock(&mutex);
}

size_t hv_native_touch_usb_state(char *json, size_t capacity) {
    pthread_mutex_lock(&mutex); expire_locked();
    int connected = usb.connected && usb.connected(usb.context);
    int n = snprintf(json, capacity, "{\"version\":1,\"epoch\":%u,\"available\":%s,\"connected\":%s,\"hostEncoding\":true,\"setupHeartbeat\":true,\"failureDetails\":true}",
                     epoch, usb.connect ? "true" : "false", connected ? "true" : "false");
    pthread_mutex_unlock(&mutex);
    return n >= 0 && (size_t)n < capacity ? (size_t)n : 0;
}

int hv_native_touch_usb_connect(uint32_t generation, int connected) {
    if (connected != 0 && connected != 1) return 0;
    pthread_mutex_lock(&mutex); expire_locked();
    int accepted = enabled && generation == epoch && usb.connect && usb.connect(usb.context, connected);
    pthread_mutex_unlock(&mutex); return accepted;
}

int hv_native_touch_usb_report(uint32_t generation, const uint8_t report[32]) {
    if (!report) return 0;
    pthread_mutex_lock(&mutex); expire_locked();
    /* The startup dispatch is neutral. Contacts cannot precede readiness. */
    int accepted = enabled && !host_encoded && generation == epoch && usb.report &&
                   (status == HV_TOUCH_READY || (status == HV_TOUCH_WAITING && report[31] == 0)) &&
                   usb.report(usb.context, report);
    pthread_mutex_unlock(&mutex); return accepted;
}

int hv_native_touch_usb_mapped(uint32_t generation) {
    pthread_mutex_lock(&mutex); expire_locked();
    int accepted = enabled && generation == epoch && usb.mapped && usb.mapped(usb.context);
    pthread_mutex_unlock(&mutex); return accepted;
}

int hv_native_touch_usb_host_encoding(uint32_t generation) {
    pthread_mutex_lock(&mutex);expire_locked();
    int accepted=enabled && generation==epoch && usb.connected && usb.connected(usb.context)
                 && usb.mapped && usb.mapped(usb.context) && usb.report;
    if(accepted && !host_encoded) {
        host_encoded=1;queued=0;memset(&current,0,sizeof current);
        memset(&encoder,0,sizeof encoder);
        if(status==HV_TOUCH_READY)encode_locked();
        pthread_cond_broadcast(&changed);
    }
    pthread_mutex_unlock(&mutex);return accepted;
}
