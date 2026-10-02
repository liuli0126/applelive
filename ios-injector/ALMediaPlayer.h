#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface ALMediaPlayer : NSObject
@property(atomic, copy) void (^onFrame)(CVPixelBufferRef frame, NSInteger rotation);
@property(atomic, copy) void (^onAudio)(const float *samples, NSUInteger frames);
@property(atomic, copy) void (^onReset)(void);
@property(atomic) BOOL paused;
@property(atomic, readonly) NSDictionary *status;
- (void)playURL:(NSURL *)url;
- (void)stop;
- (void)seek:(NSTimeInterval)seconds;
@end
