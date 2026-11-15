#include "virtio_net.h"

#include <stdlib.h>
#include <string.h>

#define F_MAC (1ull << 5)
#define F_STATUS (1ull << 16)
#define RXQ 0
#define TXQ 1
#define HDR_LEN 12 /* virtio_net_hdr with num_buffers (VERSION_1) */
#define MAX_FRAME 65550

static void notify(HvVirtio *v, int q) {
    HvVirtioNet *n = v->dev;
    if (q != TXQ) return; /* new receive buffers: nothing waiting to deliver */
    static HvVirtqElem e;
    static uint8_t frame[MAX_FRAME];
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint32_t len = hv_virtq_read(v, &e, HDR_LEN, frame, sizeof frame);
        if (n->transmit) n->transmit(n->opaque, frame, len);
        n->tx_frames++;
        hv_virtq_push(v, q, &e, 0);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

static int push_rx(HvVirtioNet *n, const uint8_t *frame, uint32_t len, int *notify_rx) {
    HvVirtio *v = &n->vio;
    static HvVirtqElem e;
    if (!(v->status & 4) || !v->q[RXQ].enabled || hv_virtq_pop(v, RXQ, &e) <= 0) return 0;
    if (hv_virtq_writable(&e) < HDR_LEN + len) { /* too small for it: drop the frame, return the buffer */
        hv_virtq_push(v, RXQ, &e, 0);
        *notify_rx = 1;
        n->rx_dropped++;
        return 1;
    }
    uint8_t hdr[HDR_LEN] = {0};
    hdr[10] = 1; /* num_buffers */
    hv_virtq_write(v, &e, 0, hdr, HDR_LEN);
    hv_virtq_write(v, &e, HDR_LEN, frame, len);
    hv_virtq_push(v, RXQ, &e, HDR_LEN + len);
    *notify_rx = 1;
    n->rx_frames++;
    return 1;
}

int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *frame, uint32_t len) {
    int notify_rx=0;
    int consumed=push_rx(n,frame,len,&notify_rx);
    if(notify_rx)hv_virtio_interrupt(&n->vio);
    return consumed;
}

/* Receive batching from oliverames' upstream PR176. Publish every used-ring
   entry normally, then signal once. An unposted buffer leaves the remaining
   frames owned by the caller, in their original order. Device lock held. */
int hv_virtio_net_receive_batch(HvVirtioNet *n,const uint8_t *const *frames,
                              const uint32_t *lengths,int count) {
    int notify_rx=0,consumed=0;
    while(consumed<count&&push_rx(n,frames[consumed],lengths[consumed],&notify_rx))consumed++;
    if(notify_rx)hv_virtio_interrupt(&n->vio);
    return consumed;
}

HvVirtioNet *hv_virtio_net_create(HvMachine *m, HvPcie *bus, const uint8_t mac[6]) {
    HvVirtioNet *n = calloc(1, sizeof *n);
    HvVirtio *v = &n->vio;
    hv_virtio_init(v, m, 1, 0x020000, 2, F_MAC | F_STATUS);
    v->dev = n;
    v->notify = notify;
    memcpy(v->config, mac, 6);
    uint16_t status = 1, pairs = 1; /* link up */
    memcpy(v->config + 6, &status, 2);
    memcpy(v->config + 8, &pairs, 2);
    v->config_len = 12;
    hv_pcie_attach(bus, &v->pci);
    return n;
}

/* The cable out (up = 0) or back in: the guest is told its configuration changed. Device lock held. */
void hv_virtio_net_set_link(HvVirtioNet *n, int up) {
    if (!n) return;
    uint16_t status = up ? 1 : 0;
    memcpy(n->vio.config + 6, &status, 2);
    hv_virtio_config_changed(&n->vio);
}
