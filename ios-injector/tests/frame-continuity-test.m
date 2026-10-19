#import "ALFrameStore.h"
#import <Foundation/Foundation.h>
#ifndef AL_FRAME_STORE_EXPIRY_PROBE
#import "ALVideoSamplePolicy.h"
#import "ALPreviewRenderer.h"
#include <stdatomic.h>
#endif
#include <stdlib.h>
#include <unistd.h>

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static CVPixelBufferRef pixel(void) {
    CVPixelBufferRef value = NULL;
    check(CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &value) == kCVReturnSuccess,
          "allocate test frame");
    return value;
}

static void checkHeld(ALFrameStore *store, CVPixelBufferRef expected) {
    CVPixelBufferRef value = [store copyLatestPixelBuffer];
    check(value == expected, "a transport gap must retain the last picture, never return the physical camera");
    if (value) CVPixelBufferRelease(value);
}

#ifndef AL_FRAME_STORE_EXPIRY_PROBE
// Real CoreMedia samples, with a display-layer transport double so tests can
// deterministically exercise queue pressure/failure without a visible window.
@interface TestDisplayLayer : AVSampleBufferDisplayLayer {
    CMSampleBufferRef _lastSample;
}
@property(nonatomic) BOOL acceptsFrames;
@property(nonatomic) AVQueuedSampleBufferRenderingStatus testStatus;
@property(nonatomic) NSUInteger removed;
@property(nonatomic) NSUInteger flushed;
@property(nonatomic) NSUInteger enqueued;
- (CVPixelBufferRef)displayedPixel;
@end
@implementation TestDisplayLayer
- (BOOL)isReadyForMoreMediaData { return self.acceptsFrames; }
- (AVQueuedSampleBufferRenderingStatus)status { return self.testStatus; }
- (void)flush { self.flushed++; self.testStatus = AVQueuedSampleBufferRenderingStatusUnknown; }
- (void)flushAndRemoveImage {
    self.removed++;
    if (_lastSample) { CFRelease(_lastSample); _lastSample = NULL; }
}
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sample {
    check(CMSampleBufferDataIsReady(sample), "preview enqueues a ready sample");
    if (_lastSample) CFRelease(_lastSample);
    _lastSample = (CMSampleBufferRef)CFRetain(sample);
    self.enqueued++;
}
- (CVPixelBufferRef)displayedPixel { return _lastSample ? CMSampleBufferGetImageBuffer(_lastSample) : NULL; }
- (void)dealloc { if (_lastSample) CFRelease(_lastSample); }
@end

static void testPreview(void) {
    TestDisplayLayer *layer = [TestDisplayLayer new];
    layer.acceptsFrames = YES;
    CVPixelBufferRef first = pixel(), second = pixel();
    ALUpdatePreviewLayer(layer, first, 1, YES);
    check(!layer.hidden && layer.displayedPixel == first, "first stream frame is visible");
    NSUInteger removed = layer.removed;
    for (NSUInteger i = 0; i < 100; i++) ALUpdatePreviewLayer(layer, NULL, 1, YES);
    check(!layer.hidden && layer.displayedPixel == first && layer.removed == removed,
          "missing preview frames must not hide the overlay or remove its image");
    layer.acceptsFrames = NO;
    ALUpdatePreviewLayer(layer, second, 1, YES);
    check(layer.displayedPixel == first && !layer.hidden, "queue pressure retains the displayed picture");
    layer.testStatus = AVQueuedSampleBufferRenderingStatusFailed;
    ALUpdatePreviewLayer(layer, second, 1, YES);
    check(layer.flushed == 1 && layer.removed == removed && layer.displayedPixel == first,
          "failed renderer flushes pending buffers without removing the displayed image");
    layer.acceptsFrames = YES;
    ALUpdatePreviewLayer(layer, second, 1, YES);
    check(layer.displayedPixel == second, "preview resumes with the next valid frame");
    ALUpdatePreviewLayer(layer, NULL, 2, YES);
    check(!layer.hidden && !layer.displayedPixel && layer.removed == removed + 1,
          "new source removes old pixels but covers physical camera while waiting");
    ALUpdatePreviewLayer(layer, first, 2, YES);
    ALUpdatePreviewLayer(layer, NULL, 2, NO);
    check(layer.hidden && !layer.displayedPixel, "explicit restore camera removes the overlay");
    ALUpdatePreviewLayer(layer, NULL, 2, YES);
    check(!layer.hidden, "reactivating while waiting covers the physical camera");
    CVPixelBufferRelease(first); CVPixelBufferRelease(second);
}

static void testCapturePolicy(void) {
    CVPixelBufferRef image = pixel();
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {CMTimeMake(1,30), CMTimeMake(1,30), kCMTimeInvalid};
    check(CMVideoFormatDescriptionCreateForImageBuffer(NULL, image, &format) == noErr, "video format");
    check(CMSampleBufferCreateForImageBuffer(NULL, image, YES, NULL, NULL, format, &timing, &sample) == noErr,
          "physical camera sample");
    check(!ALCanDeliverVideoSample(sample, YES), "replacement failure must suppress an unmodified camera frame");
    check(ALCanDeliverVideoSample(sample, NO), "explicitly disabled replacement must restore the camera");
    CMSetAttachment(sample, CFSTR("applelive_virtual"), kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    check(ALCanDeliverVideoSample(sample, YES), "already replaced video must be delivered exactly once");
    CFRelease(sample); CFRelease(format); CVPixelBufferRelease(image);
}

static atomic_int liveBuffers;
static void releaseBytes(void *ref, const void *bytes) { free((void *)bytes); atomic_fetch_sub(&liveBuffers, 1); }
static CVPixelBufferRef countedPixel(void) {
    CVPixelBufferRef value = NULL;
    void *bytes = calloc(16 * 16, 4);
    check(bytes != NULL, "allocate pixels");
    check(CVPixelBufferCreateWithBytes(NULL, 16, 16, kCVPixelFormatType_32BGRA,
          bytes, 16 * 4, releaseBytes, NULL, NULL, &value) == kCVReturnSuccess, "owned pixel buffer");
    atomic_fetch_add(&liveBuffers, 1);
    return value;
}

static void testConcurrentOwnership(void) {
    ALFrameStore *store = [ALFrameStore new];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(group, queue, ^{
        for (NSUInteger i = 0; i < 2000; i++) @autoreleasepool {
            CVPixelBufferRef value = countedPixel();
            [store storePixelBuffer:value sequence:(uint32_t)i];
            CVPixelBufferRelease(value);
        }
    });
    dispatch_group_async(group, queue, ^{
        for (NSUInteger i = 0; i < 5000; i++) @autoreleasepool {
            CVPixelBufferRef value = [store copyLatestPixelBuffer];
            if (value) { check(CVPixelBufferGetWidth(value) == 16, "retained reader frame remains valid"); CVPixelBufferRelease(value); }
            if (i % 7 == 0) [store markInterrupted];
            if (i % 23 == 0) [store clear];
            (void)[store hasFrameReceivedWithin:2];
        }
    });
    check(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
          "concurrent frame store operations must finish without deadlock");
    check(atomic_load(&liveBuffers) <= 1, "store retains at most one frame after consumers finish");
    [store clear];
    check(atomic_load(&liveBuffers) == 0, "explicit stop releases retained memory");
}
#endif

int main(void) {
    @autoreleasepool {
        ALFrameStore *store = [ALFrameStore new];
        CVPixelBufferRef first = pixel();
        [store storePixelBuffer:first sequence:1];
        checkHeld(store, first);
        usleep(900000); // Reproduce the historical 0.75-second USB expiry.
        checkHeld(store, first);
#ifndef AL_FRAME_STORE_EXPIRY_PROBE
        check(![store hasFrameReceivedWithin:0.75], "retention must not masquerade as recent reception");
        uint64_t generation = store.generation;
        [store markInterrupted];
        checkHeld(store, first);
        check(![store hasFrameReceivedWithin:60] && store.generation == generation,
              "disconnect reports stale without changing the selected source");
        CVPixelBufferRef second = pixel();
        [store storePixelBuffer:second sequence:2];
        checkHeld(store, second);
        check([store hasFrameReceivedWithin:2] && store.latestSequence == 2,
              "first recovered picture immediately replaces retained image");
        CVPixelBufferRef retained = [store copyLatestPixelBuffer];
        [store clear];
        checkHeld(store, NULL);
        check(store.generation != generation && ![store hasFrameReceivedWithin:60],
              "explicit stop/source switch clears frame and invalidates preview");
        check(CVPixelBufferGetWidth(retained) == 16, "in-flight render owns its source across clear");
        CVPixelBufferRelease(retained); CVPixelBufferRelease(second);
        testCapturePolicy(); testPreview(); testConcurrentOwnership();
#endif
        CVPixelBufferRelease(first);
        puts("PASS frame continuity, source reset, fresh status, capture suppression, preview pressure and bounded ownership");
    }
    return 0;
}
