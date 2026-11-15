/* The guest's sound on the host (Mac or iOS): the default output device through an AudioUnit
   whose render callback pulls PCM straight from the virtio-snd ring. The unit
   is set to the stream's own format, and CoreAudio converts to the device. */
#include "audio_mac.h"

#ifdef HENGE_AUDIO_TEST
#include "../tests/audio_test_api.h"
#else
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#endif

/* The Mac's default output device, or the iOS app's own output (the app sets its audio session to playback). */
#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif
#include <stdio.h>

static AudioComponentInstance unit;
static int unit_running;
static int detached, interrupted;
static unsigned cur_channels, cur_format, cur_rate;

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

static int start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    if (detached || interrupted) return -1;
    HvVirtioSnd *d = opaque;
    if (unit && (channels != cur_channels || format != cur_format || rate_hz != cur_rate)) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
        unit_running = 0;
    }
    if (!unit) {
        AudioComponentDescription desc = {kAudioUnitType_Output, HV_OUTPUT_UNIT,
                                          kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) return -1;
        unsigned bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = (format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                         kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = bytes * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = bytes * 8;
        AURenderCallbackStruct cb = {render, d};
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
            AudioUnitInitialize(unit) != noErr) {
            fprintf(stderr, "hengevm: sound: the output device refused %u ch, format %u, %u Hz\n", channels, format, rate_hz);
            AudioComponentInstanceDispose(unit);
            unit = NULL;
            return -1;
        }
        cur_channels = channels, cur_format = format, cur_rate = rate_hz;
    }
    if (!unit_running && AudioOutputUnitStart(unit) == noErr) unit_running = 1;
    return unit_running ? 0 : -1;
}

static void stop(void *opaque) {
    (void)opaque;
    if (unit && unit_running) AudioOutputUnitStop(unit); /* waits for the render callback to finish */
    unit_running = 0;
}

void hv_audio_attach(HvVirtioSnd *d) {
    detached = 0;interrupted=0;
    d->backend = (HvVirtioSndBackend){start, stop, d};
}

static void dispose_output(void) {
    detached = 1;
    stop(NULL); /* AudioOutputUnitStop waits for an in-flight render callback. */
    if (unit) {
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
        fprintf(stderr, "hengevm: sound: output stopped and AudioUnit disposed after guest exit\n");
    }
    cur_channels = cur_format = cur_rate = 0;
}
void hv_audio_pause(HvVirtioSnd *d) {
    dispose_output(); /* Preserve guest running/prepared state for snapshots. */
    if(d)d->backend.start=NULL; /* Detached audio must not restart while the VM is paused. */
}
void hv_audio_detach(HvVirtioSnd *d) {
    dispose_output();if(d)d->running=0;
}
void hv_audio_interrupt(HvVirtioSnd *d) {
    interrupted=1;stop(NULL);
    if(d){d->backend.start=NULL;hv_virtio_snd_resume(d);}
}
int hv_audio_recover(HvVirtioSnd *d) {
    if(!d || detached)return -1;
    /* Restore even a backend.start cleared after a transient AudioUnit failure.
       Recreate the unit after route/media-service changes, retaining PCM state. */
    dispose_output();hv_audio_attach(d);
    hv_virtio_snd_resume(d);
    return !d->running || d->backend.start ? 0 : -1;
}
