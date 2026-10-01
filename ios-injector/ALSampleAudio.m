#import "ALSampleAudio.h"
#import "ALAudioRing.h"
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

BOOL ALWriteInjectedPCM(const AudioStreamBasicDescription *asbd, AudioBufferList *list, NSUInteger frames,
                       ALAudioRing *ring, BOOL muted, float *scratch, NSUInteger capacity) {
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM || !frames || frames > 65536 ||
        !asbd->mChannelsPerFrame || asbd->mChannelsPerFrame > 8 || asbd->mSampleRate <= 0) return NO;
    NSUInteger channels = asbd->mChannelsPerFrame;
    BOOL planar = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    BOOL floating = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL bigEndian = (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    NSUInteger stride = asbd->mBytesPerFrame;
    NSUInteger bytes = planar ? stride : stride / channels;
    NSUInteger bits = asbd->mBitsPerChannel;
    if (!stride || bytes > 8 || !bytes || bits > bytes * 8 || !bits ||
        (floating && bits != 32 && bits != 64) || (!floating && bits > 32)) return NO;
    NSUInteger bufferCount = planar ? channels : 1;
    if (!list || list->mNumberBuffers != bufferCount || frames * channels > capacity) return NO;
    for (NSUInteger b = 0; b < bufferCount; b++)
        if (!list->mBuffers[b].mData || list->mBuffers[b].mDataByteSize < frames * stride) return NO;
    // Pop even when muted so unmuting cannot replay buffered sound.
    [ring popSamples:scratch count:frames channels:channels sampleRate:asbd->mSampleRate];
    const float *samples = scratch;
    for (NSUInteger buffer = 0; buffer < bufferCount; buffer++) {
        uint8_t *output = list->mBuffers[buffer].mData;
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
    return YES;
}
CMSampleBufferRef ALCreateInjectedAudio(CMSampleBufferRef original, ALAudioRing *ring, BOOL muted) {
    CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(original);
    const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    NSUInteger frames = CMSampleBufferGetNumSamples(original);
    if (!asbd || !frames || frames > 65536 || !asbd->mBytesPerFrame || asbd->mBytesPerFrame > 64 ||
        !asbd->mChannelsPerFrame || asbd->mChannelsPerFrame > 8) return NULL;
    BOOL planar = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    NSUInteger buffers = planar ? asbd->mChannelsPerFrame : 1;
    NSMutableData *listMemory = [NSMutableData dataWithLength:offsetof(AudioBufferList, mBuffers) + buffers * sizeof(AudioBuffer)];
    AudioBufferList *list = listMemory.mutableBytes; list->mNumberBuffers = (UInt32)buffers;
    NSUInteger length = frames * asbd->mBytesPerFrame;
    NSMutableData *memory = [NSMutableData dataWithLength:length * buffers];
    NSMutableData *pcm = [NSMutableData dataWithLength:frames * asbd->mChannelsPerFrame * sizeof(float)];
    for (NSUInteger b = 0; b < buffers; b++)
        list->mBuffers[b] = (AudioBuffer){(UInt32)(planar ? 1 : asbd->mChannelsPerFrame), (UInt32)length,
                                        (uint8_t *)memory.mutableBytes + b * length};
    if (!ALWriteInjectedPCM(asbd, list, frames, ring, muted, pcm.mutableBytes, frames * asbd->mChannelsPerFrame)) return NULL;
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) return NULL;
    CMSampleBufferRef result = NULL;
    if (CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault, NULL, NO, NULL, NULL, format,
            frames, timing.presentationTimeStamp, NULL, &result) != noErr) return NULL;
    OSStatus status = CMSampleBufferSetDataBufferFromAudioBufferList(result, kCFAllocatorDefault, kCFAllocatorDefault, 0, list);
    if (status == noErr) status = CMSampleBufferSetDataReady(result);
    if (status != noErr) { CFRelease(result); return NULL; }
    CMSetAttachment(result, CFSTR("applelive_virtual"), kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    return result;
}
