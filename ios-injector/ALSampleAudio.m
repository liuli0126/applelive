#import "ALSampleAudio.h"
#import "ALAudioRing.h"
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

CMSampleBufferRef ALCreateInjectedAudio(CMSampleBufferRef original, ALAudioRing *ring, BOOL muted) {
    CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(original);
    const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    NSUInteger frames = CMSampleBufferGetNumSamples(original);
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM || !frames || frames > 65536 ||
        !asbd->mChannelsPerFrame || asbd->mChannelsPerFrame > 8 || asbd->mSampleRate <= 0) return NULL;
    NSUInteger channels = asbd->mChannelsPerFrame;
    BOOL planar = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    BOOL floating = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL bigEndian = (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    NSUInteger stride = asbd->mBytesPerFrame;
    NSUInteger bytes = planar ? stride : stride / channels;
    NSUInteger bits = asbd->mBitsPerChannel;
    if (!stride || bytes > 8 || !bytes || bits > bytes * 8 || !bits ||
        (floating && bits != 32 && bits != 64) || (!floating && bits > 32)) return NULL;
    NSMutableData *pcm = [NSMutableData dataWithLength:frames * channels * sizeof(float)];
    // Pop even when muted so unmuting cannot replay buffered sound.
    [ring popSamples:pcm.mutableBytes count:frames channels:channels sampleRate:asbd->mSampleRate];
    const float *samples = pcm.bytes;
    NSUInteger bufferCount = planar ? channels : 1;
    NSMutableData *listMemory = [NSMutableData dataWithLength:offsetof(AudioBufferList, mBuffers) + bufferCount * sizeof(AudioBuffer)];
    AudioBufferList *list = listMemory.mutableBytes;
    list->mNumberBuffers = (UInt32)bufferCount;
    NSMutableData *memory = [NSMutableData dataWithLength:frames * stride * bufferCount];
    for (NSUInteger buffer = 0; buffer < bufferCount; buffer++) {
        uint8_t *output = (uint8_t *)memory.mutableBytes + buffer * frames * stride;
        list->mBuffers[buffer] = (AudioBuffer){(UInt32)(planar ? 1 : channels), (UInt32)(frames * stride), output};
        for (NSUInteger i = 0; i < frames; i++) for (NSUInteger c = 0; c < (planar ? 1 : channels); c++) {
            float value = muted ? 0 : samples[i * channels + (planar ? buffer : c)];
            if (!isfinite(value)) value = 0;
            value = fmaxf(-1, fminf(1, value));
            uint64_t word = 0;
            if (floating) {
                if (bits == 32) { float f = value; uint32_t raw; memcpy(&raw, &f, 4); word = raw; }
                else { double f = value; memcpy(&word, &f, 8); }
            } else {
                int64_t maximum = ((int64_t)1 << (bits - 1)) - 1;
                int64_t number = llround(value * maximum);
                if (!(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger)) number += (int64_t)1 << (bits - 1);
                word = (uint64_t)number & (UINT64_MAX >> (64 - bits));
                if (asbd->mFormatFlags & kAudioFormatFlagIsAlignedHigh) word <<= bytes * 8 - bits;
            }
            uint8_t *destination = output + i * stride + c * bytes;
            for (NSUInteger b = 0; b < bytes; b++) destination[b] = (uint8_t)(word >> (8 * (bigEndian ? bytes - b - 1 : b)));
        }
    }
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) return NULL;
    CMSampleBufferRef result = NULL;
    if (CMSampleBufferCreate(kCFAllocatorDefault, NULL, NO, NULL, NULL, format, frames, 1, &timing, 0, NULL, &result) != noErr) return NULL;
    OSStatus status = CMSampleBufferSetDataBufferFromAudioBufferList(result, kCFAllocatorDefault, kCFAllocatorDefault, 0, list);
    if (status == noErr) status = CMSampleBufferSetDataReady(result);
    if (status != noErr) { CFRelease(result); return NULL; }
    CMSetAttachment(result, CFSTR("applelive_virtual"), kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    return result;
}
