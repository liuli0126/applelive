#import <Foundation/Foundation.h>

NSDictionary *ALConnectionSettings(void);
BOOL ALParseComputerAddress(NSString *address, NSString **host, NSNumber **port);
BOOL ALParseRTMPStreamURL(NSString *address, NSString **host);
NSString *ALRTMPStreamURL(NSDictionary *settings);
BOOL ALPublishConnection(NSDictionary *settings);
void ALObserveConnection(void (^handler)(NSDictionary *settings));
void ALPersistConnection(NSDictionary *settings);
NSArray<NSString *> *ALConnectionAddresses(NSDictionary *settings);
