/* The guest's sound on the host (Mac or iOS): the default output device through an AudioUnit
   whose render callback pulls PCM straight from the virtio-snd ring. The unit
   is set to the stream's own format, and CoreAudio converts to the device. */
#include "audio_mac.h"

#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>

/* The Mac's default output device, or the iOS app's own output (the app sets its audio session to playback). */
#include <stdint.h>
#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif
#include <stdio.h>
#include <stdlib.h>

static AudioComponentInstance unit;
static int unit_running;
static unsigned cur_channels, cur_format, cur_rate;

#if TARGET_OS_IPHONE
/* Stop and start the playing output unit. Returns 1 if it was playing. */
static int out_unit_restart(void) {
    if (!unit || !unit_running || getenv("HV_MIC_NO_RESTART")) return 0;
    AudioOutputUnitStop(unit);
    unit_running = AudioOutputUnitStart(unit) == noErr;
    return 1;
}

/* The microphone: a second RemoteIO unit with only its input bus on, set to the guest's capture
   format, so the unit converts from the hardware's. The app puts its audio session in
   play-and-record and asks for permission first (Microphone.swift); without them this fails or
   records silence, and either way the guest's capture stream keeps running. */
static AudioComponentInstance in_unit;
static unsigned in_frame_bytes, in_channels;
static uint8_t in_buf[1 << 16];
static int in_logged_first, in_logged_fail;
static FILE *in_dump;
static uint64_t in_dumped, in_dump_max;

static OSStatus capture(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                        UInt32 frames, AudioBufferList *io) {
    (void)io;
    HvVirtioSnd *d = ref;
    UInt32 bytes = frames * in_frame_bytes;
    if (!in_unit || !bytes || bytes > sizeof in_buf) return noErr;
    AudioBufferList bl;
    bl.mNumberBuffers = 1;
    bl.mBuffers[0].mNumberChannels = in_channels;
    bl.mBuffers[0].mDataByteSize = bytes;
    bl.mBuffers[0].mData = in_buf;
    OSStatus st = AudioUnitRender(in_unit, flags, ts, bus, frames, &bl);
    if (st == noErr) hv_virtio_snd_push(d, in_buf, bl.mBuffers[0].mDataByteSize);
    /* The first 15 s of each recording as the phone's microphone gave it, in Documents/mic-capture.raw (the Mac's
       format: see the log line), to tell static made here from static made on the way to the Mac. HV_MIC_DUMP=0: none. */
    if (st == noErr && in_dump) {
        UInt32 n = bl.mBuffers[0].mDataByteSize;
        if (in_dumped + n > in_dump_max) n = in_dump_max > in_dumped ? (UInt32)(in_dump_max - in_dumped) : 0;
        if (n) fwrite(in_buf, 1, n, in_dump), in_dumped += n;
        if (in_dumped >= in_dump_max) fclose(in_dump), in_dump = NULL;
    }
    /* The first callback of a recording and the first failure, for the log (once each: this is the audio thread). */
    if (!in_logged_first) {
        in_logged_first = 1;
        fprintf(stderr, "hengevm: sound: microphone delivering, %u frames a callback (status %d)\n", (unsigned)frames, (int)st);
    }
    if (st != noErr && !in_logged_fail) {
        in_logged_fail = 1;
        fprintf(stderr, "hengevm: sound: reading the microphone failed (status %d, %u frames)\n", (int)st, (unsigned)frames);
    }
    return noErr;
}

static void in_stop(void *opaque) {
    (void)opaque;
    if (!in_unit) return;
    AudioOutputUnitStop(in_unit); /* waits for the capture callback to finish */
    if (in_dump) fclose(in_dump), in_dump = NULL;
    AudioUnitUninitialize(in_unit);
    AudioComponentInstanceDispose(in_unit);
    in_unit = NULL;
}

static int in_start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    HvVirtioSnd *d = opaque;
    in_stop(opaque);
    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstance u = NULL;
    if (!comp || AudioComponentInstanceNew(comp, &u) != noErr) return -1;
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
    UInt32 on = 1, off = 0;
    AURenderCallbackStruct cb = {capture, d};
    OSStatus st;
    /* Bus 1 is the microphone, bus 0 the speaker: this unit records only (the output unit above plays). */
    if ((st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof on)) != noErr ||
        (st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof off)) != noErr ||
        (st = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof f)) != noErr ||
        (st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof cb)) != noErr ||
        (st = AudioUnitInitialize(u)) != noErr) {
        fprintf(stderr, "hengevm: sound: the microphone refused %u ch, format %u, %u Hz (status %d)\n", channels, format, rate_hz, (int)st);
        AudioComponentInstanceDispose(u);
        return -1;
    }
    in_frame_bytes = bytes * channels;
    in_channels = channels;
    if (in_dump) fclose(in_dump), in_dump = NULL;
    if (!getenv("HV_MIC_DUMP") || atoi(getenv("HV_MIC_DUMP"))) {
        char path[1024];
        snprintf(path, sizeof path, "%s/Documents/mic-capture.raw", getenv("HOME") ? getenv("HOME") : ".");
        in_dump = fopen(path, "wb");
        in_dumped = 0, in_dump_max = (uint64_t)rate_hz * in_frame_bytes * 15;
        fprintf(stderr, "hengevm: sound: the microphone's first 15 s go to Documents/mic-capture.raw (%u ch, %s, %u Hz)%s\n", channels,
                format == HV_VSND_FMT_FLOAT ? "32-bit float" : format == HV_VSND_FMT_S16 ? "16-bit" : "32-bit integer", rate_hz, in_dump ? "" : ": could not open it");
    }
    in_logged_first = in_logged_fail = 0;
    in_unit = u;
    if ((st = AudioOutputUnitStart(u)) != noErr) {
        fprintf(stderr, "hengevm: sound: the microphone did not start (status %d)\n", (int)st);
        in_stop(opaque);
        return -1;
    }
    /* The input coming on changes the audio session's route (a route change is logged at this moment), and the
       output unit, running since before it, can be left without callbacks: the Mac's one sound device then stops
       its whole I/O cycle, input included. Start the output again on the new route. HV_MIC_NO_RESTART: leave it. */
    if (out_unit_restart() && !getenv("HV_MIC_NO_RESTART"))
        fprintf(stderr, "hengevm: sound: the output was restarted for the microphone's route\n");
    return 0;
}
#endif

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

static int start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
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
    d->backend = (HvVirtioSndBackend){start, stop, d};
#if TARGET_OS_IPHONE
    d->backend.in_start = in_start;
    d->backend.in_stop = in_stop;
#endif
}

void hv_audio_detach(void) {
#if TARGET_OS_IPHONE
    in_stop(NULL);
#endif
    if (unit) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
    }
    unit_running = 0;
    cur_channels = cur_format = cur_rate = 0;
}
