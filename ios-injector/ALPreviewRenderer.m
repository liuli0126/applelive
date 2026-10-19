#import "ALPreviewRenderer.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const void *kALPreviewGeneration = &kALPreviewGeneration;

void ALUpdatePreviewLayer(AVSampleBufferDisplayLayer *layer, CVPixelBufferRef pixel,
                          uint64_t generation, BOOL active) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSNumber *previous = objc_getAssociatedObject(layer, kALPreviewGeneration);
    if (!previous || previous.unsignedLongLongValue != generation || !active) {
        if (!layer.hidden || !previous || previous.unsignedLongLongValue != generation)
            [layer flushAndRemoveImage];
        // The overlay has an opaque background. While waiting for the first
        // frame of a selected source, cover the physical camera as well.
        layer.hidden = !active;
        objc_setAssociatedObject(layer, kALPreviewGeneration, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (active) layer.hidden = NO;
    if (active && pixel) {
        // flush preserves the displayed image; flushAndRemoveImage is reserved
        // for an explicit source change/stop, never a missed frame or backpressure.
        if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
        if (layer.readyForMoreMediaData) {
            CMVideoFormatDescriptionRef format = NULL;
            CMSampleBufferRef sample = NULL;
            CMSampleTimingInfo timing = {kCMTimeInvalid,
                CMTimeMakeWithSeconds(CACurrentMediaTime(), 600), kCMTimeInvalid};
            if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel, &format) == noErr &&
                CMSampleBufferCreateForImageBuffer(NULL, pixel, YES, NULL, NULL, format, &timing, &sample) == noErr) {
                CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
                if (attachments && CFArrayGetCount(attachments))
                    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                        kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
                [layer enqueueSampleBuffer:sample];
                layer.hidden = NO;
            }
            if (sample) CFRelease(sample);
            if (format) CFRelease(format);
        }
    }
    [CATransaction commit];
}
