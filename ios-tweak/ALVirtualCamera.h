#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@class ALFrameStore;
@class ALAudioRing;

@interface ALVirtualCamera : NSObject

@property(nonatomic, readonly) ALFrameStore *frameStore;
@property(nonatomic, readonly) ALAudioRing *audioRing;
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;

+ (instancetype)sharedInstance;
- (void)start;
- (CMSampleBufferRef)replacementForVideoSample:(CMSampleBufferRef)original;
- (CMSampleBufferRef)replacementForAudioSample:(CMSampleBufferRef)original;

@end
