#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface ALFrameStore : NSObject
// Clearing a source changes this token; transport interruptions do not.
@property(nonatomic, readonly) uint64_t generation;

- (void)storePixelBuffer:(CVPixelBufferRef)pixelBuffer sequence:(uint32_t)sequence;
- (CVPixelBufferRef)copyLatestPixelBuffer;
- (uint32_t)latestSequence;
- (BOOL)hasFrameReceivedWithin:(NSTimeInterval)interval;
- (void)markInterrupted;
- (void)clear;

@end
