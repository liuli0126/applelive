#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Experimental user-space UVC acquisition. The host App's sandbox/entitlements
// determine whether IOKit access is allowed; signing a dylib cannot grant them.
@interface ALExternalCamera : NSObject
@property(atomic, copy) void (^onFrame)(CVPixelBufferRef frame);
// The service forwards original UVC bytes over loopback, avoiding another
// encode/decode cycle. Only one of onRawFrame and onFrame is used per instance.
@property(atomic, copy) void (^onRawFrame)(NSData *packet);
@property(atomic, copy, readonly) NSDictionary *status;
- (void)start;
- (void)stop;
- (void)stopAndWait;
- (NSString *)diagnosticReport;
@end
