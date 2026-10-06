#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

typedef void (^ALDecodedFrameHandler)(CVPixelBufferRef pixelBuffer, uint32_t sequence);

@interface ALVideoDecoder : NSObject

@property(nonatomic, copy) ALDecodedFrameHandler onFrame;
- (void)decodeNAL:(NSData *)nalData sequence:(uint32_t)sequence;
- (void)decodeAccessUnit:(NSData *)data sequence:(uint32_t)sequence flags:(uint32_t)flags;
- (void)reset;

@end
