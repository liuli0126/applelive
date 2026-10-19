#import <CoreMedia/CoreMedia.h>

// A missing/failed replacement is not permission to expose the physical
// camera while the user has selected an injected video source. Audio and
// samples already replaced by another hook continue through unchanged.
static inline BOOL ALCanDeliverVideoSample(CMSampleBufferRef sample, BOOL replacementActive) {
    if (!replacementActive || !sample) return YES;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (format && CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) return YES;
    return CMGetAttachment(sample, CFSTR("applelive_virtual"), NULL) != NULL;
}
