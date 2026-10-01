#import "ALControls.h"
#import <notify.h>
#import <os/log.h>
#import <time.h>

#ifndef APPLELIVE_STANDALONE
static const char *kALControlNotification = "com.applelive.controls.v1";
#endif
static const char *kALStatusNotification = "com.applelive.status.v1";
static NSString *const kALSavedControls = @"AppleLive.Controls.v1";
#ifndef APPLELIVE_STANDALONE
static const uint64_t kALControlMagic = UINT64_C(0x414c000100000000);
#endif

#ifndef APPLELIVE_STANDALONE
static int ALControlToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notify_register_check(kALControlNotification, &token); });
    return token;
}
#endif

static int ALStatusToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notify_register_check(kALStatusNotification, &token); });
    return token;
}

NSDictionary *ALDefaultControls(NSString *bundleIdentifier) {
    return @{@"enabled": @YES, @"audio": @NO, @"muted": @NO, @"mirror": @NO, @"fill": @NO,
             @"rotation": @0, @"cameraPortrait": @([bundleIdentifier isEqualToString:@"com.apple.camera"])};
}

#ifndef APPLELIVE_STANDALONE
static uint64_t ALEncodeControls(NSDictionary *controls) {
    return kALControlMagic |
        ([controls[@"enabled"] boolValue] ? 1 : 0) |
        ([controls[@"audio"] boolValue] ? 2 : 0) |
        ([controls[@"mirror"] boolValue] ? 4 : 0) |
        ([controls[@"fill"] boolValue] ? 8 : 0) |
        ((uint64_t)([controls[@"rotation"] unsignedIntegerValue] % 4) << 4) |
        ([controls[@"cameraPortrait"] boolValue] ? 64 : 0);
}

static NSDictionary *ALDecodeControls(uint64_t state) {
    if ((state & UINT64_C(0xffffffff00000000)) != kALControlMagic) return nil;
    return @{@"enabled": @((state & 1) != 0), @"audio": @((state & 2) != 0),
             @"mirror": @((state & 4) != 0), @"fill": @((state & 8) != 0),
             @"rotation": @((state >> 4) & 3), @"cameraPortrait": @((state & 64) != 0)};
}
#endif

NSDictionary *ALLoadAppControls(void) {
    NSMutableDictionary *controls = [ALDefaultControls(NSBundle.mainBundle.bundleIdentifier) mutableCopy];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kALSavedControls];
    for (NSString *key in @[@"enabled", @"audio", @"muted", @"mirror", @"fill", @"rotation"]) {
        if ([saved[key] isKindOfClass:NSNumber.class]) controls[key] = saved[key];
    }
#ifdef APPLELIVE_STANDALONE
    return controls;
#else
    return ALDecodeControls(ALEncodeControls(controls));
#endif
}

BOOL ALPublishControls(NSDictionary *controls) {
#ifdef APPLELIVE_STANDALONE
    [NSNotificationCenter.defaultCenter postNotificationName:@"AppleLive.InjectorControls" object:controls];
    return YES;
#else
    int token = ALControlToken();
    if (token < 0) return NO;
    uint32_t result = notify_set_state(token, ALEncodeControls(controls));
    if (result == NOTIFY_STATUS_OK) result = notify_post(kALControlNotification);
    if (result != NOTIFY_STATUS_OK) {
        os_log_error(OS_LOG_DEFAULT, "[AppleLive] controls publish failed: %u", result);
    }
    return result == NOTIFY_STATUS_OK;
#endif
}

BOOL ALSaveAndPublishControls(NSDictionary *controls) {
    [NSUserDefaults.standardUserDefaults setObject:controls forKey:kALSavedControls];
    return ALPublishControls(controls);
}

NSDictionary *ALCurrentControls(void) {
#ifdef APPLELIVE_STANDALONE
    return ALLoadAppControls();
#else
    uint64_t state = 0;
    int token = ALControlToken();
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return nil;
    return ALDecodeControls(state);
#endif
}

void ALObserveControls(void (^handler)(NSDictionary *controls)) {
#ifdef APPLELIVE_STANDALONE
    [NSNotificationCenter.defaultCenter addObserverForName:@"AppleLive.InjectorControls" object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            handler(notification.object);
        }];
#else
    int token = -1;
    uint32_t result = notify_register_dispatch(kALControlNotification, &token,
        dispatch_get_main_queue(), ^(int registeredToken) {
            uint64_t state = 0;
            if (notify_get_state(registeredToken, &state) == NOTIFY_STATUS_OK) {
                NSDictionary *controls = ALDecodeControls(state);
                if (controls) handler(controls);
            }
        });
    if (result != NOTIFY_STATUS_OK) {
        os_log_error(OS_LOG_DEFAULT, "[AppleLive] controls listener failed: %u", result);
    }
#endif
}

void ALPublishStreamStatus(BOOL connected, BOOL usb, BOOL video, BOOL audio) {
    int token = ALStatusToken();
    if (token < 0) return;
    uint64_t state = ((uint64_t)(uint32_t)time(NULL) << 32) | 0x100 |
        (connected ? 1 : 0) | (usb ? 2 : 0) | (video ? 4 : 0) | (audio ? 8 : 0);
    notify_set_state(token, state);
}

NSDictionary *ALReadStreamStatus(void) {
    uint64_t state = 0;
    int token = ALStatusToken();
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return @{};
    int64_t age = (int64_t)time(NULL) - (int64_t)(state >> 32);
    if ((state & 0x100) == 0 || age < 0 || age > 4) return @{};
    return @{@"connected": @((state & 1) != 0), @"usb": @((state & 2) != 0),
             @"video": @((state & 4) != 0), @"audio": @((state & 8) != 0)};
}
