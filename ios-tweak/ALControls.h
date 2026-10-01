#import <Foundation/Foundation.h>

NSDictionary *ALDefaultControls(NSString *bundleIdentifier);
NSDictionary *ALLoadAppControls(void);
BOOL ALSaveAndPublishControls(NSDictionary *controls);
BOOL ALPublishControls(NSDictionary *controls);
NSDictionary *ALCurrentControls(void);
void ALObserveControls(void (^handler)(NSDictionary *controls));
void ALPublishStreamStatus(BOOL connected, BOOL usb, BOOL video, BOOL audio);
NSDictionary *ALReadStreamStatus(void);
