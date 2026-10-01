#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
@class ALAudioRing;
CMSampleBufferRef ALCreateInjectedAudio(CMSampleBufferRef original, ALAudioRing *ring, BOOL muted) CF_RETURNS_RETAINED;
BOOL ALWriteInjectedPCM(const AudioStreamBasicDescription *asbd, AudioBufferList *list, NSUInteger frames,
                       ALAudioRing *ring, BOOL muted, float *scratch, NSUInteger capacity);
