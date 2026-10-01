#import <CoreMedia/CoreMedia.h>
@class ALAudioRing;
CMSampleBufferRef ALCreateInjectedAudio(CMSampleBufferRef original, ALAudioRing *ring, BOOL muted) CF_RETURNS_RETAINED;
