#ifndef HENGE_AUDIO_TEST_API_H
#define HENGE_AUDIO_TEST_API_H
#include <stdint.h>
#ifdef TARGET_OS_IPHONE
#undef TARGET_OS_IPHONE
#endif
#define TARGET_OS_IPHONE 1
typedef int32_t OSStatus;
typedef uint32_t UInt32, AudioUnitRenderActionFlags;
typedef struct { double sample; } AudioTimeStamp;
typedef struct { UInt32 mNumberChannels, mDataByteSize; void *mData; } AudioBuffer;
typedef struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[1]; } AudioBufferList;
typedef OSStatus (*RenderFn)(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
typedef struct { RenderFn inputProc; void *inputProcRefCon; } AURenderCallbackStruct;
typedef struct { UInt32 type, subtype, manufacturer, flags, mask; } AudioComponentDescription;
typedef struct { double mSampleRate; UInt32 mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket, mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel; } AudioStreamBasicDescription;
typedef struct TestAudioUnit *AudioComponentInstance;
typedef void *AudioComponent;
enum { noErr=0, kAudioUnitType_Output=1, kAudioUnitSubType_RemoteIO, kAudioUnitSubType_DefaultOutput,
       kAudioUnitManufacturer_Apple, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat=8,
       kAudioFormatFlagIsSignedInteger=16, kAudioFormatFlagIsPacked=32,
       kAudioUnitProperty_StreamFormat=64, kAudioUnitProperty_SetRenderCallback,
       kAudioUnitScope_Input };
AudioComponent AudioComponentFindNext(AudioComponent, const AudioComponentDescription *);
OSStatus AudioComponentInstanceNew(AudioComponent, AudioComponentInstance *);
OSStatus AudioUnitSetProperty(AudioComponentInstance, UInt32, UInt32, UInt32, const void *, UInt32);
OSStatus AudioUnitInitialize(AudioComponentInstance);
OSStatus AudioOutputUnitStart(AudioComponentInstance);
OSStatus AudioOutputUnitStop(AudioComponentInstance);
OSStatus AudioUnitUninitialize(AudioComponentInstance);
OSStatus AudioComponentInstanceDispose(AudioComponentInstance);
#endif
