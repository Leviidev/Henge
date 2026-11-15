/* Exercise the real backend source with a synchronous test AudioUnit API.
   Native IPA compilation separately checks the real Apple SDK signatures. */
#define HENGE_AUDIO_TEST
#include "../host/audio_mac.c"
#include <assert.h>
#include <string.h>

struct TestAudioUnit { int initialized, running, disposed; AURenderCallbackStruct cb; AudioStreamBasicDescription format; };
static struct TestAudioUnit instances[16];
static int fail_start;
static unsigned created, starts, stops, uninits, disposals, pulls;
AudioComponent AudioComponentFindNext(AudioComponent previous, const AudioComponentDescription *d) { (void)previous; assert(d->subtype == HV_OUTPUT_UNIT); return instances; }
OSStatus AudioComponentInstanceNew(AudioComponent c, AudioComponentInstance *u) { assert(c && created<16); *u=&instances[created++]; return noErr; }
OSStatus AudioUnitSetProperty(AudioComponentInstance u, UInt32 p, UInt32 scope, UInt32 element, const void *value, UInt32 bytes) {
    assert(scope==kAudioUnitScope_Input && element==0);
    if (p==kAudioUnitProperty_StreamFormat) { assert(bytes==sizeof u->format); memcpy(&u->format,value,bytes); }
    else { assert(p==kAudioUnitProperty_SetRenderCallback && bytes==sizeof u->cb); memcpy(&u->cb,value,bytes); }
    return noErr;
}
OSStatus AudioUnitInitialize(AudioComponentInstance u) { assert(!u->disposed); u->initialized=1; return noErr; }
OSStatus AudioOutputUnitStart(AudioComponentInstance u) { assert(u->initialized && !u->disposed);if(fail_start)return -1; u->running=1; starts++; return noErr; }
OSStatus AudioOutputUnitStop(AudioComponentInstance u) { assert(u->running && !u->disposed); u->running=0; stops++; return noErr; }
OSStatus AudioUnitUninitialize(AudioComponentInstance u) { assert(!u->running && u->initialized); u->initialized=0; uninits++; return noErr; }
OSStatus AudioComponentInstanceDispose(AudioComponentInstance u) { assert(!u->running && !u->initialized && !u->disposed); u->disposed=1; disposals++; return noErr; }
uint32_t hv_virtio_snd_pull(HvVirtioSnd *d, void *buf, uint32_t len) { assert(d); pulls++; memset(buf,0,len); return len; }
void hv_virtio_snd_resume(HvVirtioSnd *d) {
    if(d->running && d->backend.start && d->backend.start(d->backend.opaque,d->channels,d->format,d->rate_hz))d->backend.start=NULL;
}
int main(void) {
    HvVirtioSnd d = {0};
    hv_audio_attach(&d);
    assert(d.backend.start(d.backend.opaque,2,HV_VSND_FMT_S16,48000)==0);
    assert(created==1 && starts==1 && instances[0].running);
    assert(d.backend.start(d.backend.opaque,2,HV_VSND_FMT_S16,48000)==0 && starts==1);
    unsigned char pcm[32]; memset(pcm,255,sizeof pcm);
    AudioBufferList output = {.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=sizeof pcm,.mData=pcm}}};
    assert(instances[0].cb.inputProc(instances[0].cb.inputProcRefCon,NULL,NULL,0,8,&output)==noErr && pulls==1);
    for(unsigned i=0;i<sizeof pcm;i++) assert(pcm[i]==0);
    d.running=1;
    hv_audio_detach(&d);
    assert(!d.running && !instances[0].running && instances[0].disposed && stops==1 && uninits==1 && disposals==1);
    assert(d.backend.start(d.backend.opaque,2,HV_VSND_FMT_S16,48000)==-1 && created==1); /* late guest request */
    hv_audio_detach(&d);
    assert(stops==1 && disposals==1); /* idempotent */
    hv_audio_attach(&d);
    assert(d.backend.start(d.backend.opaque,1,HV_VSND_FMT_S16,44100)==0 && created==2);
    assert(d.backend.start(d.backend.opaque,2,HV_VSND_FMT_FLOAT,48000)==0 && created==3);
    assert(stops==2 && uninits==2 && disposals==2);
    hv_audio_detach(&d);
    assert(stops==3 && uninits==3 && disposals==3 && !unit && !unit_running);
    hv_audio_attach(&d);d.channels=2;d.format=HV_VSND_FMT_S16;d.rate_hz=48000;d.running=1;
    assert(d.backend.start(d.backend.opaque,2,HV_VSND_FMT_S16,48000)==0);
    hv_audio_pause(&d);assert(d.running && !unit && detached && !d.backend.start);
    hv_audio_attach(&d);hv_virtio_snd_resume(&d);assert(d.running && unit_running);
    hv_audio_interrupt(&d);assert(d.running && !unit_running && interrupted);
    assert(!d.backend.start && start(&d,2,HV_VSND_FMT_S16,48000)==-1);
    assert(hv_audio_recover(&d)==0 && unit_running && d.running && !interrupted);
    fail_start=1;assert(hv_audio_recover(&d)==-1 && !d.backend.start && d.running);
    fail_start=0;assert(hv_audio_recover(&d)==0 && d.backend.start && unit_running && d.running);
    hv_audio_detach(&d);unsigned count=created;
    assert(hv_audio_recover(&d)==-1 && created==count);
    puts("audio lifecycle: render, no duplicate start, stop/uninitialize/dispose, late-start rejection, idempotence, pause stream preservation, interruption, failed-start recovery and reattach passed");
}
