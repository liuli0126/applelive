#import <Foundation/Foundation.h>
@interface ALUSBReceiver : NSObject
@property(atomic, copy) void (^onConnected)(void);
@property(atomic, copy) void (^onDisconnected)(void);
@property(atomic, copy) void (^onBinary)(NSData *data);
- (void)start;
- (void)stop;
@end
