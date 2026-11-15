#ifndef HENGEVM_AUDIO_MAC_H
#define HENGEVM_AUDIO_MAC_H

#include "virtio_snd.h"

/* Play the guest's virtio-snd output on the Mac's default output device. */
void hv_audio_attach(HvVirtioSnd *d);
/* Caller holds the device lock. Stop callbacks and release the AudioUnit;
   a late guest request cannot restart it before another attach. */
void hv_audio_detach(HvVirtioSnd *d);
/* Device lock required. Pause preserves the guest stream, unlike destruction. */
void hv_audio_pause(HvVirtioSnd *d);
void hv_audio_interrupt(HvVirtioSnd *d);
int hv_audio_recover(HvVirtioSnd *d);

#endif
