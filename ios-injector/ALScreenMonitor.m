#import "ALScreenMonitor.h"
#import <Vision/Vision.h>
#include <math.h>

#if __has_include("ALMonitorConfig.h")
#import "ALMonitorConfig.h"
#else
#define AL_DEFAULT_MONITOR_ENDPOINT @""
#endif

static NSTimeInterval const kALMonitorInterval = 1.5;
static NSTimeInterval const kALMonitorRetryInterval = 30.0;
static NSString *const kALMonitorDeviceKey = @"AppleLive.Monitor.Device.v1";
static NSString *const kALMonitorAccountKey = @"AppleLive.Monitor.Account.v1";
static NSString *const kALMonitorEndpointKey = @"AppleLive.Monitor.Endpoint.v1";
static NSString *const kALMonitorPendingKey = @"AppleLive.Monitor.Pending.v1";
static NSString *const kALMonitorEnabledKey = @"AppleLive.Monitor.Enabled.v1";
static NSString *const kALDefaultMonitorEndpoint = AL_DEFAULT_MONITOR_ENDPOINT;

@implementation ALMonitorTextLine
+ (instancetype)lineWithText:(NSString *)text bounds:(CGRect)bounds {
    ALMonitorTextLine *line = [ALMonitorTextLine new];
    line.text = text ?: @"";
    line.bounds = bounds;
    return line;
}
@end

static NSString *ALNormalizedText(NSString *value) {
    NSCharacterSet *punctuation = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n.,!?，。、《》：！？；;()（）【】[]{}\"'“”‘’"];
    return [[value ?: @"" componentsSeparatedByCharactersInSet:punctuation] componentsJoinedByString:@""];
}

static BOOL ALButtonMatches(NSString *value) {
    NSString *text = ALNormalizedText(value), *target = @"开始检测";
    if (text.length < target.length) return NO;
    for (NSUInteger offset = 0; offset + target.length <= text.length; offset++) {
        NSUInteger different = 0;
        for (NSUInteger i = 0; i < target.length; i++)
            if ([text characterAtIndex:offset + i] != [target characterAtIndex:i]) different++;
        if (different <= 1) return YES;
    }
    return NO;
}

static BOOL ALLiveRoomNoticeMatches(NSArray<ALMonitorTextLine *> *lines, CGSize size) {
    for (ALMonitorTextLine *line in lines) {
        NSString *text = ALNormalizedText(line.text);
        CGFloat top = CGRectGetMinY(line.bounds) * size.height;
        // Live-room status notices are rendered in the main content area. A
        // matching chat message near the bottom should not trigger the alert.
        if (top < size.height * 0.15 || top > size.height * 0.68) continue;
        if ([text rangeOfString:@"主播违规整改中"].location != NSNotFound ||
            [text rangeOfString:@"主播暂时离开"].location != NSNotFound) return YES;
        if ([text rangeOfString:@"主播离开一会儿"].location != NSNotFound &&
            [text rangeOfString:@"耐心等候"].location != NSNotFound) return YES;
    }
    return NO;
}

BOOL ALMonitorPopupMatches(NSArray<ALMonitorTextLine *> *lines, CGSize size) {
    if (size.width < 1 || size.height < 1) return NO;
    // Douyin can show a full-screen live-room remediation notice instead of
    // the account-security dialog. It is an independent alert condition and
    // does not have the title/button layout used by the dialog below.
    if (ALLiveRoomNoticeMatches(lines, size)) return YES;
    for (ALMonitorTextLine *title in lines) {
        NSString *titleText = ALNormalizedText(title.text);
        if ([titleText rangeOfString:@"保障账号安全"].location == NSNotFound) continue;
        CGFloat titleTop = CGRectGetMinY(title.bounds) * size.height;
        CGFloat titleBottom = CGRectGetMaxY(title.bounds) * size.height;
        if (titleTop < size.height * 0.02 || titleTop > size.height * 0.65) continue;
        for (ALMonitorTextLine *verify in lines) {
            NSString *verifyText = ALNormalizedText(verify.text);
            if ([verifyText rangeOfString:@"进行验证"].location == NSNotFound) continue;
            CGFloat verifyTop = CGRectGetMinY(verify.bounds) * size.height;
            if (fabs(verifyTop - titleTop) > size.height * 0.16) continue;
            for (ALMonitorTextLine *button in lines) {
                if (!ALButtonMatches(button.text)) continue;
                CGFloat buttonTop = CGRectGetMinY(button.bounds) * size.height;
                CGFloat buttonLeft = CGRectGetMinX(button.bounds) * size.width;
                CGFloat buttonRight = CGRectGetMaxX(button.bounds) * size.width;
                if (buttonTop <= MAX(titleBottom, CGRectGetMaxY(verify.bounds) * size.height) ||
                    buttonTop - titleTop > size.height * 0.65 ||
                    buttonLeft > size.width * 0.80 || buttonRight < size.width * 0.20) continue;
                for (ALMonitorTextLine *body in lines) {
                    NSString *bodyText = ALNormalizedText(body.text);
                    BOOL bodyMatch = [bodyText rangeOfString:@"账号存在风险"].location != NSNotFound ||
                        [bodyText rangeOfString:@"人脸信息处理"].location != NSNotFound;
                    CGFloat bodyTop = CGRectGetMinY(body.bounds) * size.height;
                    if (bodyMatch && bodyTop >= MIN(titleTop, verifyTop) && bodyTop < buttonTop) return YES;
                }
            }
        }
    }
    return NO;
}

static BOOL ALValidEndpoint(NSString *raw) {
    NSURLComponents *components = [NSURLComponents componentsWithString:raw ?: @""];
    if (![components.scheme.lowercaseString isEqualToString:@"https"] || components.host.length == 0 ||
        components.user.length || components.password.length || components.query.length || components.fragment.length) return NO;
    NSArray<NSString *> *parts = [components.path componentsSeparatedByString:@"/"];
    if (parts.count != 3 || ![parts[1] isEqualToString:@"mobile-alerts"] || parts[2].length < 32) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return [parts[2] rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

static UIWindow *ALMonitorWindow(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.01 || window.bounds.size.width < 1 || window.bounds.size.height < 1 || window.windowLevel >= UIWindowLevelAlert) continue;
            NSString *className = NSStringFromClass(window.class);
            if ([className containsString:@"PassThroughWindow"] || [className containsString:@"InjectedFloatingPanel"]) continue;
            [windows addObject:window];
        }
    }
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.isKeyWindow != b.isKeyWindow) return a.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        if (a.windowLevel != b.windowLevel) return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return windows.firstObject;
}

static UIImage *ALCaptureWindowImage(void) {
    UIWindow *window = ALMonitorWindow();
    if (!window) return nil;
    CGRect bounds = window.bounds;
    CGFloat scale = MIN(1.0, 1080.0 / MAX(bounds.size.width, bounds.size.height));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = MAX(0.5, scale); format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor blackColor] setFill]; UIRectFill(bounds);
        [window drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
    }];
}

@interface ALScreenMonitor ()
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, copy, readwrite) NSString *status;
@property(nonatomic, copy, readwrite) NSString *deviceName;
@property(nonatomic, copy, readwrite) NSString *accountName;
@property(nonatomic, copy, readwrite) NSString *endpoint;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSTimer *retryTimer;
@property(nonatomic) BOOL recognitionPending;
@property(nonatomic) BOOL latched;
@property(nonatomic) NSUInteger positive;
@property(nonatomic) NSUInteger clear;
@property(nonatomic) NSTimeInterval lastPositive;
@property(nonatomic) NSTimeInterval clearSince;
@property(nonatomic, copy) NSDictionary *pendingPayload;
@end

@implementation ALScreenMonitor
+ (instancetype)sharedMonitor {
    static ALScreenMonitor *monitor; static dispatch_once_t once;
    dispatch_once(&once, ^{ monitor = [ALScreenMonitor new]; }); return monitor;
}

- (instancetype)init {
    if ((self = [super init])) {
        _status = @"未开启监控";
        _deviceName = [NSUserDefaults.standardUserDefaults stringForKey:kALMonitorDeviceKey] ?: @"";
        _accountName = [NSUserDefaults.standardUserDefaults stringForKey:kALMonitorAccountKey] ?: @"";
        NSString *storedEndpoint = [NSUserDefaults.standardUserDefaults stringForKey:kALMonitorEndpointKey];
        _endpoint = kALDefaultMonitorEndpoint.length ? kALDefaultMonitorEndpoint : (storedEndpoint ?: @"");
        NSDictionary *pending = [NSUserDefaults.standardUserDefaults dictionaryForKey:kALMonitorPendingKey];
        _pendingPayload = [pending isKindOfClass:NSDictionary.class] ? pending : nil;
        _lastPositive = -1; _clearSince = -1;
    }
    return self;
}

- (void)publish:(NSString *)status {
    self.status = status ?: @"";
    ALScreenMonitorStatusHandler handler = self.onStatus;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(self.status, self.running); });
}

- (void)startWithDeviceName:(NSString *)deviceName accountName:(NSString *)accountName endpoint:(NSString *)endpoint {
    if (self.running) return;
    NSString *device = [deviceName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *account = [accountName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *candidate = kALDefaultMonitorEndpoint.length ? kALDefaultMonitorEndpoint : endpoint;
    if (candidate.length == 0) candidate = self.endpoint;
    NSString *url = [candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (device.length == 0 || account.length == 0) { [self publish:@"请填写手机名称和直播账号"]; return; }
    if (!ALValidEndpoint(url)) { [self publish:@"预警服务不可用，请联系管理员"]; return; }
    self.deviceName = device; self.accountName = account; self.endpoint = url;
    [NSUserDefaults.standardUserDefaults setObject:device forKey:kALMonitorDeviceKey];
    [NSUserDefaults.standardUserDefaults setObject:account forKey:kALMonitorAccountKey];
    [NSUserDefaults.standardUserDefaults setObject:url forKey:kALMonitorEndpointKey];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kALMonitorEnabledKey];
    self.running = YES; self.latched = NO; self.positive = 0; self.clear = 0; self.lastPositive = -1; self.clearSince = -1;
    [self.retryTimer invalidate]; self.retryTimer = nil; [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:kALMonitorInterval target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self publish:self.pendingPayload ? @"正在检测抖音画面，待发送提醒将自动重试" : @"正在检测抖音画面"];
    if (self.pendingPayload) [self sendPendingAlert];
    [self tick];
}

- (void)stop {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kALMonitorEnabledKey];
    if (!self.running && !self.timer) return;
    self.running = NO; [self.timer invalidate]; self.timer = nil; [self.retryTimer invalidate]; self.retryTimer = nil;
    self.recognitionPending = NO; [self publish:@"监控已停止"];
}

- (void)pauseForBackground {
    if (!self.running && !self.timer) return;
    self.running = NO; [self.timer invalidate]; self.timer = nil; [self.retryTimer invalidate]; self.retryTimer = nil;
    self.recognitionPending = NO; [self publish:@"等待直播间回到前台"];
}

- (void)resumeIfEnabled {
    if (self.running || ![NSUserDefaults.standardUserDefaults boolForKey:kALMonitorEnabledKey] ||
        self.deviceName.length == 0 || self.accountName.length == 0) return;
    [self startWithDeviceName:self.deviceName accountName:self.accountName endpoint:@""];
}

- (void)tick {
    if (!self.running || self.recognitionPending || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIImage *image = ALCaptureWindowImage();
    if (!image.CGImage) { [self publish:@"暂未取得抖音画面"]; return; }
    self.recognitionPending = YES; CGImageRef cgImage = CGImageRetain(image.CGImage); CGSize imageSize = image.size;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSMutableArray<ALMonitorTextLine *> *lines = [NSMutableArray array];
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
            if (error) return;
            for (VNRecognizedTextObservation *observation in request.results) {
                VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
                if (candidate.string.length) {
                    CGRect bounds = observation.boundingBox;
                    // Vision uses a bottom-left origin; the detector uses top-left coordinates.
                    bounds.origin.y = 1.0 - CGRectGetMaxY(observation.boundingBox);
                    [lines addObject:[ALMonitorTextLine lineWithText:candidate.string bounds:bounds]];
                }
            }
        }];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        request.usesLanguageCorrection = YES;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
        NSError *error = nil; [handler performRequests:@[request] error:&error]; CGImageRelease(cgImage);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.recognitionPending = NO; if (!self.running) return;
            if (error) { [self publish:@"画面识别暂不可用，正在重试"]; return; }
            NSUInteger textLength = 0; for (ALMonitorTextLine *line in lines) textLength += line.text.length;
            [self observeMatch:ALMonitorPopupMatches(lines, imageSize) usable:textLength >= 12];
        });
    });
}

- (void)observeMatch:(BOOL)match usable:(BOOL)usable {
    if (!usable) { self.positive = 0; self.clear = 0; self.clearSince = -1; [self publish:@"画面文字不足，正在重试"]; return; }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (match) {
        self.clear = 0; self.clearSince = -1;
        if (self.latched) { [self publish:@"已识别直播间提示，请手动处理"]; return; }
        // A single completed OCR match is enough to notify. The latch below
        // prevents duplicate notifications while the same popup remains on
        // screen; it is cleared only after the popup has disappeared.
        self.positive = 1;
        self.lastPositive = now;
        self.latched = YES; self.positive = 0; [self enqueueAlert];
    } else {
        self.positive = 0; self.lastPositive = -1;
        if (self.clearSince < 0) self.clearSince = now;
        self.clear++;
        if (self.latched && self.clear >= 8 && now - self.clearSince >= 12) self.latched = NO;
        [self publish:self.latched ? @"已提醒，请处理后等待弹窗消失" : @"正在检测抖音画面"];
    }
}

- (void)enqueueAlert {
    if (self.pendingPayload) { [self publish:@"已识别直播间提示，上一条群提醒仍在重试"]; return; }
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithColonSeparatorInTimeZone;
    self.pendingPayload = @{@"eventId": NSUUID.UUID.UUIDString.lowercaseString, @"deviceName": self.deviceName,
        @"accountName": self.accountName, @"kind": @"security_verification", @"occurredAt": [formatter stringFromDate:NSDate.date]};
    [NSUserDefaults.standardUserDefaults setObject:self.pendingPayload forKey:kALMonitorPendingKey];
    [self publish:@"已识别直播间提示，正在提交群提醒"]; [self sendPendingAlert];
}

- (void)sendPendingAlert {
    if (!self.running || !self.pendingPayload) return;
    NSError *error = nil; NSData *data = [NSJSONSerialization dataWithJSONObject:self.pendingPayload options:0 error:&error];
    if (error) { [self publish:@"提醒数据生成失败"]; return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.endpoint]];
    request.HTTPMethod = @"POST"; request.timeoutInterval = 12; request.HTTPBody = data;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *body, NSURLResponse *response, NSError *networkError) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode]; BOOL accepted = NO;
        if (!networkError && (code == 200 || code == 202) && body.length) {
            NSDictionary *result = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil]; accepted = [result[@"accepted"] boolValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running) return;
            if (accepted) {
                self.pendingPayload = nil; [NSUserDefaults.standardUserDefaults removeObjectForKey:kALMonitorPendingKey];
                [self.retryTimer invalidate]; self.retryTimer = nil; [self publish:@"群提醒已提交"]; return;
            }
            if (networkError || code == 408 || code == 429 || code >= 500 || code == 0) {
                [self publish:@"提醒提交失败，30 秒后重试"]; [self.retryTimer invalidate];
                self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:kALMonitorRetryInterval target:self selector:@selector(sendPendingAlert) userInfo:nil repeats:NO];
            } else [self publish:[NSString stringWithFormat:@"提醒服务拒绝请求（HTTP %ld）", (long)code]];
        });
    }] resume];
}
@end
