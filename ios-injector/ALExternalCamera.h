#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Experimental user-space UVC acquisition. The host App's sandbox/entitlements
// determine whether IOKit access is allowed; signing a dylib cannot grant them.
@interface ALExternalCamera : NSObject
@property(atomic, copy) void (^onFrame)(CVPixelBufferRef frame);
@property(atomic, copy, readonly) NSDictionary *status;
- (void)start;
- (void)stop;
- (NSString *)diagnosticReport;
@end
