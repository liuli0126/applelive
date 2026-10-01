#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface ALFrameStore : NSObject
@property(atomic) BOOL holdsFrame;

- (void)storePixelBuffer:(CVPixelBufferRef)pixelBuffer sequence:(uint32_t)sequence;
- (CVPixelBufferRef)copyLatestPixelBuffer;
- (uint32_t)latestSequence;
- (void)clear;

@end
