#import <Foundation/Foundation.h>
#import "ALProtocol.h"

@interface ALStreamClient : NSObject <NSURLSessionWebSocketDelegate, NSURLSessionTaskDelegate>

@property(nonatomic, copy) ALVideoNALHandler onVideoNAL;
@property(nonatomic, copy) ALAudioPCMHandler onAudioPCM;
@property(nonatomic, copy) void (^onDisconnected)(void);
@property(atomic, readonly, getter=isConnected) BOOL connected;
@property(atomic, copy, readonly) NSString *address;

- (void)connectToAddress:(NSString *)address;
- (void)connectToAddresses:(NSArray<NSString *> *)addresses;
- (void)disconnect;

@end
