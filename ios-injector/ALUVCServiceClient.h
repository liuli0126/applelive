#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
@interface ALUVCServiceClient : NSObject
@property(atomic, copy) void (^onFrame)(CVPixelBufferRef frame);
@property(atomic, copy, readonly) NSDictionary *status;
+ (BOOL)saveConnectionCode:(NSString *)code;
- (instancetype)initWithPort:(uint16_t)port;
- (void)start;
- (void)stop;
- (NSString *)diagnosticReport;
@end
