#import <Foundation/Foundation.h>

NSDictionary *ALConnectionSettings(void);
BOOL ALParseComputerAddress(NSString *address, NSString **host, NSNumber **port);
BOOL ALPublishConnection(NSDictionary *settings);
void ALObserveConnection(void (^handler)(NSDictionary *settings));
void ALPersistConnection(NSDictionary *settings);
NSArray<NSString *> *ALConnectionAddresses(NSDictionary *settings);
