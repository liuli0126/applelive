#import "ALMediaPlayer.h"
#import "ALSampleAudio.h"
#import "ALAudioRing.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>

static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}
static void testAudio(void) {
    ALAudioRing *ring = [ALAudioRing new];
    for (int planar = 0; planar <= 1; planar++) for (int floating = 0; floating <= 1; floating++) {
        AudioStreamBasicDescription asbd = {0};
        asbd.mSampleRate = 48000; asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsPacked | (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
            (planar ? kAudioFormatFlagIsNonInterleaved : 0);
        asbd.mChannelsPerFrame = 2; asbd.mFramesPerPacket = 1;
        asbd.mBitsPerChannel = floating ? 32 : 16;
        asbd.mBytesPerFrame = asbd.mBytesPerPacket = (floating ? 4 : 2) * (planar ? 1 : 2);
        CMAudioFormatDescriptionRef format = NULL;
        require(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &format) == noErr, "audio format");
        CMSampleTimingInfo timing = {CMTimeMake(1, 48000), CMTimeMake(100, 48000), kCMTimeInvalid};
        CMSampleBufferRef original = NULL;
        require(CMSampleBufferCreate(NULL, NULL, NO, NULL, NULL, format, 128, 1, &timing, 0, NULL, &original) == noErr, "audio sample");
        float pcm[256]; for (int i = 0; i < 256; i++) pcm[i] = i % 2 ? -0.25 : 0.5;
        [ring clear]; [ring pushSamples:pcm count:128 channels:2 sampleRate:48000];
        CMSampleBufferRef output = ALCreateInjectedAudio(original, ring, NO);
        require(output != NULL && CMSampleBufferGetNumSamples(output) == 128, "audio injection");
        AudioBufferList *list = calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
        CMBlockBufferRef block = NULL;
        require(CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(output, NULL, list,
            offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer), NULL, NULL, 0, &block) == noErr, "audio buffers");
        require(list->mNumberBuffers == (planar ? 2 : 1), "PCM layout preserved");
        if (floating) require(fabs(((float *)list->mBuffers[0].mData)[0] - 0.5) < 0.001, "float audio amplitude");
        else require(abs(((int16_t *)list->mBuffers[0].mData)[0] - 16384) < 2, "integer audio amplitude");
        CFRelease(block); CFRelease(output);
        // Underflow must replace the original microphone with silence.
        output = ALCreateInjectedAudio(original, ring, NO);
        require(output != NULL, "underflow preserves injection");
        block = NULL;
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(output, NULL, list,
            offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer), NULL, NULL, 0, &block);
        for (UInt32 b = 0; b < list->mNumberBuffers; b++) for (UInt32 i = 0; i < list->mBuffers[b].mDataByteSize; i++)
            require(((uint8_t *)list->mBuffers[b].mData)[i] == 0, "underflow silence");
        CFRelease(block); CFRelease(output); CFRelease(original); CFRelease(format); free(list);
    }
}
int main(int argc, char **argv) {
    @autoreleasepool {
        require(argc == 2, "fixture path required"); testAudio();
        ALMediaPlayer *player = [ALMediaPlayer new];
        __block atomic_uint frames, audioFrames;
        atomic_init(&frames, 0); atomic_init(&audioFrames, 0);
        player.onFrame = ^(CVPixelBufferRef frame, NSInteger rotation) {
            require(CVPixelBufferGetWidth(frame) == 320 && CVPixelBufferGetHeight(frame) == 240, "decoded video dimensions");
            atomic_fetch_add(&frames, 1);
        };
        player.onAudio = ^(const float *pcm, NSUInteger count) {
            for (NSUInteger i = 0; i < count * 2; i++) require(isfinite(pcm[i]) && fabs(pcm[i]) <= 1.1, "decoded audio range");
            atomic_fetch_add(&audioFrames, (unsigned)count);
        };
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        [player playURL:url];
        for (int i = 0; i < 100 && atomic_load(&frames) < 10; i++) usleep(50000);
        require(atomic_load(&frames) >= 10, "local decode starts");
        player.paused = YES; usleep(200000);
        unsigned count = atomic_load(&frames); usleep(200000);
        require(atomic_load(&frames) == count, "pause stops video decode");
        player.paused = NO; [player seek:1.2]; usleep(450000);
        require([player.status[@"position"] doubleValue] >= 1.2, "seek honors target");
        usleep(1700000);
        require([player.status[@"state"] isEqualToString:@"playing"], "local loop continues");
        require(atomic_load(&audioFrames) > 10000, "AAC audio decodes");
        [player stop]; usleep(100000); count = atomic_load(&frames); usleep(150000);
        require(atomic_load(&frames) == count, "cancel stops decoder");
        puts("Media playback, pause, seek, loop, cancellation and PCM injection passed");
    }
    return 0;
}
