#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "ALStreamClient.h"
#import "ALVideoDecoder.h"
#include <math.h>

static uint32_t LE(const uint8_t *p) {
    return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static NSArray<NSData *> *Packets(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSCAssert(data.length, @"fixture missing: %@", path);
    NSMutableArray *packets = [NSMutableArray new];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger offset = 0; offset < data.length;) {
        NSCAssert(data.length - offset >= 4, @"truncated frame header");
        uint32_t size = CFSwapInt32BigToHost(*(const uint32_t *)(bytes + offset));
        offset += 4;
        NSCAssert(size >= 4 && size <= data.length - offset, @"truncated frame");
        [packets addObject:[data subdataWithRange:NSMakeRange(offset, size)]];
        offset += size;
    }
    return packets;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSCAssert(argc == 3, @"expected native and multi-slice fixture paths");
        NSArray<NSData *> *native = Packets(@(argv[1]));
        NSArray<NSData *> *multi = Packets(@(argv[2]));
        ALStreamClient *stream = [ALStreamClient new];
        ALVideoDecoder *decoder = [ALVideoDecoder new];
        __block NSUInteger pictures = 0, audioFrames = 0;
        __block double audioEnergy = 0;
        decoder.onFrame = ^(CVPixelBufferRef image, uint32_t sequence) {
            NSCAssert(image && CVPixelBufferGetWidth(image) > 0, @"empty decoded frame");
            pictures++;
            (void)sequence;
        };
        stream.onVideoNAL = ^(NSData *data, uint32_t sequence, uint32_t flags, uint32_t w, uint32_t h) {
            [decoder decodeAccessUnit:data sequence:sequence flags:flags];
            (void)w; (void)h;
        };
        stream.onAudioPCM = ^(const float *pcm, NSUInteger frames, uint32_t channels, double rate) {
            NSCAssert(rate == 48000 && channels == 2 && frames <= 1024, @"unexpected AAC output");
            for (NSUInteger i = 0; i < frames * channels; i++) {
                NSCAssert(isfinite(pcm[i]), @"nonfinite audio sample");
                audioEnergy += fabs(pcm[i]);
            }
            audioFrames += frames;
        };
        NSMutableArray<NSData *> *video = [NSMutableArray new];
        for (NSData *packet in native) {
            [stream acceptBinaryData:packet];
            if (packet.length > 20 && memcmp(packet.bytes, "fram", 4) == 0) [video addObject:packet];
        }
        NSCAssert(pictures == video.count && pictures >= 60, @"native frame loss: %lu/%lu", pictures, video.count);
        NSCAssert(audioFrames >= 80000 && audioEnergy > 1, @"AAC produced no usable audio: %lu %f", audioFrames, audioEnergy);

        [stream disconnect]; [decoder reset]; pictures = 0;
        for (NSData *packet in multi) [stream acceptBinaryData:packet];
        NSCAssert(pictures == 20, @"multi-slice frames must decode as complete pictures: %lu", pictures);

        [decoder reset]; pictures = 0;
        [stream acceptBinaryData:video[0]];
        [stream acceptBinaryData:video[1]];
        NSCAssert(pictures == 2, @"initial IDR did not decode");
        // Simulate bounded sender queue overflow: lose one dependent frame.
        NSUInteger before = pictures;
        BOOL recovered = NO;
        for (NSUInteger i = 3; i < video.count; i++) {
            NSData *packet = video[i];
            BOOL keyframe = (LE((const uint8_t *)packet.bytes + 8) & 1) != 0;
            [stream acceptBinaryData:packet];
            if (keyframe) { recovered = pictures == before + 1; break; }
            NSCAssert(pictures == before, @"delta displayed after sequence gap");
        }
        NSCAssert(recovered, @"did not resume on IDR after gap");

        // Concurrent teardown used to free the AAC decoder while USB used it.
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_group_async(group, queue, ^{
            for (NSUInteger round = 0; round < 5; round++)
                for (NSData *packet in native) if (memcmp(packet.bytes, "fram", 4)) [stream acceptBinaryData:packet];
        });
        dispatch_group_async(group, queue, ^{
            for (NSUInteger i = 0; i < 100; i++) [stream disconnect];
        });
        NSCAssert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0, @"teardown deadlock");
        for (NSUInteger size = 0; size < 24; size++) [stream acceptBinaryData:[NSMutableData dataWithLength:size]];
        [stream disconnect]; [decoder reset]; pictures = 0;
        for (NSData *packet in native) [stream acceptBinaryData:packet];
        NSCAssert(pictures == video.count, @"reconnect decode failed");
        NSLog(@"PASS USB native H264/AAC, multi-slice, gap recovery, concurrent disconnect and reconnect");
    }
    return 0;
}
