#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ALMonitorTextLine;

typedef void (^ALScreenMonitorStatusHandler)(NSString *status, BOOL running);

@interface ALMonitorTextLine : NSObject
@property(nonatomic, copy) NSString *text;
@property(nonatomic) CGRect bounds;
+ (instancetype)lineWithText:(NSString *)text bounds:(CGRect)bounds;
@end

BOOL ALMonitorPopupMatches(NSArray<ALMonitorTextLine *> *lines, CGSize size);

@interface ALScreenMonitor : NSObject
+ (instancetype)sharedMonitor;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, copy, readonly) NSString *status;
@property(nonatomic, copy, readonly) NSString *deviceName;
@property(nonatomic, copy, readonly) NSString *accountName;
@property(nonatomic, copy, readonly) NSString *endpoint;
@property(nonatomic, copy, nullable) ALScreenMonitorStatusHandler onStatus;
- (void)startWithDeviceName:(NSString *)deviceName accountName:(NSString *)accountName endpoint:(NSString *)endpoint;
- (void)resumeIfEnabled;
- (void)pauseForBackground;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
