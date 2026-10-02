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
- (NSDictionary *)streamStatus;
- (CMSampleBufferRef)replacementForVideoSample:(CMSampleBufferRef)original;
- (CMSampleBufferRef)replacementForAudioSample:(CMSampleBufferRef)original;
#ifdef APPLELIVE_STANDALONE
- (void)selectSource:(NSString *)kind URL:(NSURL *)url;
- (NSDictionary *)mediaStatus;
- (void)setMediaPaused:(BOOL)paused;
- (void)seekMedia:(NSTimeInterval)seconds;
- (CVPixelBufferRef)copyPreviewPixelBuffer:(CGSize)size CF_RETURNS_RETAINED;
- (NSData *)sourceJPEG;
#endif

@end
