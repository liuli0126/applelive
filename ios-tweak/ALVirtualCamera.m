#import "ALVirtualCamera.h"
#import "ALAudioRing.h"
#import "ALFrameStore.h"
#import "ALStreamClient.h"
#import "ALVideoDecoder.h"
#import "ALControls.h"
#import "ALConnection.h"
#import "ALColorPipeline.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#ifndef APPLELIVE_STANDALONE
#import <substrate.h>
#endif
#import <os/log.h>
#import <math.h>
#ifdef APPLELIVE_STANDALONE
#import "ALMediaPlayer.h"
#import "ALPreview.h"
#import "ALSampleAudio.h"
#import "ALUSBReceiver.h"
#import "ALAudioUnitBridge.h"
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#endif

static const void *kALVideoProxyKey = &kALVideoProxyKey;
static const void *kALAudioProxyKey = &kALAudioProxyKey;
static BOOL gALHooksInstalled = NO;
static CMSampleBufferRef (*gOriginalBWCopyNext)(id, SEL) = NULL;
static void (*gOriginalBWEmitSample)(id, SEL, CMSampleBufferRef) = NULL;
static void (*gOriginalVideoSetDelegate)(id, SEL, id, dispatch_queue_t) = NULL;
static void (*gOriginalAudioSetDelegate)(id, SEL, id, dispatch_queue_t) = NULL;

static void ALHookMessage(Class cls, SEL selector, IMP replacement, IMP *original) {
#ifdef APPLELIVE_STANDALONE
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = class_getMethodImplementation(cls, selector);
    // Add an inherited method to this class before replacing its implementation.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    }
#else
    MSHookMessageEx(cls, selector, replacement, original);
#endif
}

@interface ALVirtualCamera ()
@property(nonatomic, readwrite) ALFrameStore *frameStore;
@property(nonatomic, readwrite) ALAudioRing *audioRing;
@property(nonatomic) ALStreamClient *client;
@property(nonatomic) ALVideoDecoder *decoder;
@property(nonatomic) BOOL started;
@property(nonatomic) CIContext *renderContext;
@property(atomic, copy) NSDictionary *controls;
@property(atomic, assign) CFAbsoluteTime lastVideoTime;
@property(atomic, assign) BOOL connectionPaused;
@property(atomic, assign) CFAbsoluteTime lastAudioTime;
@property(nonatomic, strong) dispatch_source_t statusTimer;
@property(nonatomic, copy) NSArray<NSString *> *connectionAddresses;
#ifdef APPLELIVE_STANDALONE
@property(nonatomic) ALMediaPlayer *mediaPlayer;
@property(nonatomic) ALAudioRing *unitAudioRing;
@property(atomic, copy) NSString *sourceKind;
@property(nonatomic) NSURL *sourceURL;
@property(atomic) NSInteger sourceRotation;
@property(nonatomic) ALUSBReceiver *usbReceiver;
@property(atomic) BOOL directUSB;
#endif
- (BOOL)renderVideoIntoSample:(CMSampleBufferRef)sample;
- (void)pushAudioSamples:(const float *)samples count:(NSUInteger)count channels:(NSUInteger)channels sampleRate:(double)rate;
- (void)clearAudioSamples;
#ifdef APPLELIVE_STANDALONE
- (void)configureAudioBridge;
#endif
@end

@interface ALDelegateProxy : NSObject
- (instancetype)initWithTarget:(id)target owner:(ALVirtualCamera *)owner audio:(BOOL)audio;
@end

static CMSampleBufferRef ALCreateVideoSample(CVPixelBufferRef pixelBuffer,
                                             CMSampleBufferRef reference) {
    if (!pixelBuffer) return NULL;
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        return NULL;
    }
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    if (reference && CMSampleBufferGetNumSamples(reference) > 0) {
        CMSampleTimingInfo sourceTiming;
        if (CMSampleBufferGetSampleTimingInfo(reference, 0, &sourceTiming) == noErr) timing = sourceTiming;
    }
    CMSampleBufferRef output = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES,
                                                         NULL, NULL, format, &timing, &output);
    CFRelease(format);
    if (status == noErr && output) {
        CMSetAttachment((CMAttachmentBearerRef)output, CFSTR("applelive_virtual"),
                        kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    }
    return output;
}

static CMSampleBufferRef ALHookBWCopyNext(id self, SEL selector) {
    CMSampleBufferRef original = gOriginalBWCopyNext ? gOriginalBWCopyNext(self, selector) : NULL;
    ALVirtualCamera *camera = [ALVirtualCamera sharedInstance];
    CMSampleBufferRef replacement = [camera replacementForVideoSample:original];
    if (!replacement) return original;
    if (original) CFRelease(original);
    return replacement;
}

static void ALHookBWEmitSample(id self, SEL selector, CMSampleBufferRef sample) {
    @autoreleasepool {
        static uint64_t calls = 0;
        uint64_t count = __sync_add_and_fetch(&calls, 1);
        BOOL replaced = [[ALVirtualCamera sharedInstance] renderVideoIntoSample:sample];
        if (count == 1 || count % 900 == 0) {
            CVImageBufferRef image = sample ? CMSampleBufferGetImageBuffer(sample) : NULL;
            os_log(OS_LOG_DEFAULT, "[AppleLive] BW emit calls=%llu replaced=%d image=%dx%d",
                   count, replaced, image ? (int)CVPixelBufferGetWidth(image) : 0,
                   image ? (int)CVPixelBufferGetHeight(image) : 0);
        }
        if (gOriginalBWEmitSample) gOriginalBWEmitSample(self, selector, sample);
    }
}

static void ALHookVideoSetDelegate(id self, SEL selector, id delegate, dispatch_queue_t queue) {
    ALVirtualCamera *camera = [ALVirtualCamera sharedInstance];
    if (delegate) {
        ALDelegateProxy *proxy = [[ALDelegateProxy alloc] initWithTarget:delegate owner:camera audio:NO];
        objc_setAssociatedObject(self, kALVideoProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        delegate = proxy;
    } else {
        objc_setAssociatedObject(self, kALVideoProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (gOriginalVideoSetDelegate) gOriginalVideoSetDelegate(self, selector, delegate, queue);
}

static void ALHookAudioSetDelegate(id self, SEL selector, id delegate, dispatch_queue_t queue) {
    ALVirtualCamera *camera = [ALVirtualCamera sharedInstance];
    if (delegate) {
        ALDelegateProxy *proxy = [[ALDelegateProxy alloc] initWithTarget:delegate owner:camera audio:YES];
        objc_setAssociatedObject(self, kALAudioProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        delegate = proxy;
    } else {
        objc_setAssociatedObject(self, kALAudioProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (gOriginalAudioSetDelegate) gOriginalAudioSetDelegate(self, selector, delegate, queue);
}

static void ALInstallHooks(void) {
    if (gALHooksInstalled) return;
    gALHooksInstalled = YES;

    Class bwNodeOutput = NSClassFromString(@"BWNodeOutput");
    Method copyMethod = bwNodeOutput ? class_getInstanceMethod(bwNodeOutput, @selector(copyNextSampleBuffer)) : NULL;
    char copyReturnType[128] = {0};
    if (copyMethod) method_getReturnType(copyMethod, copyReturnType, sizeof(copyReturnType));
    if (copyMethod && method_getNumberOfArguments(copyMethod) == 2 && copyReturnType[0] == '^') {
        ALHookMessage(bwNodeOutput, @selector(copyNextSampleBuffer),
                        (IMP)ALHookBWCopyNext, (IMP *)&gOriginalBWCopyNext);
    }
    // iOS 13 pushes frames through emitSampleBuffer: instead of exposing a
    // copyNextSampleBuffer accessor. Keep the pipeline's original buffers,
    // dimensions, timing and attachments when painting the incoming image.
    SEL emitSelector = NSSelectorFromString(@"emitSampleBuffer:");
    Method emitMethod = bwNodeOutput ? class_getInstanceMethod(bwNodeOutput, emitSelector) : NULL;
    if (!gOriginalBWCopyNext && emitMethod && method_getNumberOfArguments(emitMethod) == 3) {
        char returnType[16] = {0};
        char argumentType[128] = {0};
        method_getReturnType(emitMethod, returnType, sizeof(returnType));
        method_getArgumentType(emitMethod, 2, argumentType, sizeof(argumentType));
        if (returnType[0] == 'v' && argumentType[0] == '^') {
            ALHookMessage(bwNodeOutput, emitSelector, (IMP)ALHookBWEmitSample,
                           (IMP *)&gOriginalBWEmitSample);
        }
    }
    os_log(OS_LOG_DEFAULT, "[AppleLive] BW hooks class=%d copy=%d emit=%d signature=%{public}s",
           bwNodeOutput != Nil, gOriginalBWCopyNext != NULL, gOriginalBWEmitSample != NULL,
           emitMethod ? method_getTypeEncoding(emitMethod) : "absent");

    Class videoOutput = [AVCaptureVideoDataOutput class];
    if (videoOutput) {
        ALHookMessage(videoOutput, @selector(setSampleBufferDelegate:queue:),
                        (IMP)ALHookVideoSetDelegate, (IMP *)&gOriginalVideoSetDelegate);
    }
    Class audioOutput = [AVCaptureAudioDataOutput class];
    if (audioOutput) {
        ALHookMessage(audioOutput, @selector(setSampleBufferDelegate:queue:),
                        (IMP)ALHookAudioSetDelegate, (IMP *)&gOriginalAudioSetDelegate);
    }
    os_log(OS_LOG_DEFAULT, "[AppleLive] camera hooks installed");
}

@implementation ALDelegateProxy {
    __weak id _target;
    __weak ALVirtualCamera *_owner;
    BOOL _audio;
}

- (instancetype)initWithTarget:(id)target owner:(ALVirtualCamera *)owner audio:(BOOL)audio {
    self = [super init];
    if (self) {
        _target = target;
        _owner = owner;
        _audio = audio;
    }
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    return [_target respondsToSelector:selector] || [super respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if (selector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return nil;
    return _target;
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id target = _target;
    ALVirtualCamera *owner = _owner;
    if (!target) return;
    CMSampleBufferRef replacement = NULL;
    if (_audio) replacement = [owner replacementForAudioSample:sampleBuffer];
    else replacement = [owner replacementForVideoSample:sampleBuffer];
    CMSampleBufferRef delivered = replacement ?: sampleBuffer;
    if ([target respondsToSelector:_cmd]) {
        [target captureOutput:output didOutputSampleBuffer:delivered fromConnection:connection];
    }
    if (replacement) CFRelease(replacement);
}

@end

@implementation ALVirtualCamera

+ (instancetype)sharedInstance {
    static ALVirtualCamera *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)pushAudioSamples:(const float *)samples count:(NSUInteger)count channels:(NSUInteger)channels sampleRate:(double)rate {
    [self.audioRing pushSamples:samples count:count channels:channels sampleRate:rate];
#ifdef APPLELIVE_STANDALONE
    // Capture delegates and AudioUnit input may run together; each needs its own read cursor.
    [self.unitAudioRing pushSamples:samples count:count channels:channels sampleRate:rate];
#endif
}
- (void)clearAudioSamples {
    [self.audioRing clear];
#ifdef APPLELIVE_STANDALONE
    [self.unitAudioRing clear];
#endif
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameStore = [[ALFrameStore alloc] init];
        _audioRing = [[ALAudioRing alloc] init];
        _client = [[ALStreamClient alloc] init];
        _decoder = [[ALVideoDecoder alloc] init];
#ifdef APPLELIVE_STANDALONE
        _sourceKind = @"none";
        _unitAudioRing = [ALAudioRing new];
        _mediaPlayer = [ALMediaPlayer new];
        _usbReceiver = [ALUSBReceiver new];
#endif
        __weak typeof(self) weakSelf = self;
        _decoder.onFrame = ^(CVPixelBufferRef pixelBuffer, uint32_t sequence) {
            if (weakSelf.connectionPaused) return;
#ifdef APPLELIVE_STANDALONE
            if (![weakSelf.sourceKind isEqualToString:@"usb"]) return;
#endif
            [weakSelf.frameStore storePixelBuffer:pixelBuffer sequence:sequence];
            weakSelf.lastVideoTime = CFAbsoluteTimeGetCurrent();
        };
        _client.onVideoNAL = ^(NSData *nal, uint32_t sequence, uint32_t flags,
                               uint32_t width, uint32_t height) {
            [weakSelf.decoder decodeAccessUnit:nal sequence:sequence flags:flags];
            (void)flags;
            (void)width;
            (void)height;
        };
        _client.onAudioPCM = ^(const float *samples, NSUInteger count,
                               uint32_t channels, double rate) {
            [weakSelf pushAudioSamples:samples count:count channels:channels sampleRate:rate];
            weakSelf.lastAudioTime = CFAbsoluteTimeGetCurrent();
        };
        _client.onDisconnected = ^{
#ifdef APPLELIVE_STANDALONE
            if (weakSelf.directUSB || ![weakSelf.sourceKind isEqualToString:@"usb"]) return;
#endif
            weakSelf.lastVideoTime = 0;
            weakSelf.lastAudioTime = 0;
            [weakSelf.decoder reset];
            [weakSelf.frameStore clear];
            [weakSelf clearAudioSamples];
        };
#ifdef APPLELIVE_STANDALONE
        _mediaPlayer.onFrame = ^(CVPixelBufferRef frame, NSInteger rotation) {
            if ([weakSelf.sourceKind isEqualToString:@"usb"]) return;
            weakSelf.sourceRotation = rotation;
            [weakSelf.frameStore storePixelBuffer:frame sequence:weakSelf.frameStore.latestSequence + 1];
            weakSelf.lastVideoTime = CFAbsoluteTimeGetCurrent();
        };
        _mediaPlayer.onAudio = ^(const float *samples, NSUInteger frames) {
            if ([weakSelf.sourceKind isEqualToString:@"usb"]) return;
            [weakSelf pushAudioSamples:samples count:frames channels:2 sampleRate:48000];
            weakSelf.lastAudioTime = CFAbsoluteTimeGetCurrent();
        };
        _mediaPlayer.onReset = ^{
            if ([weakSelf.sourceKind isEqualToString:@"usb"]) return;
            [weakSelf clearAudioSamples];
            if ([weakSelf.sourceKind isEqualToString:@"network"]) [weakSelf.frameStore clear];
        };
        _usbReceiver.onConnected = ^{
            weakSelf.directUSB = YES;
            [weakSelf.client disconnect];
            [weakSelf.decoder reset]; [weakSelf.frameStore clear]; [weakSelf clearAudioSamples];
        };
        _usbReceiver.onBinary = ^(NSData *data) {
            if (weakSelf.directUSB && !weakSelf.connectionPaused && [weakSelf.sourceKind isEqualToString:@"usb"])
                [weakSelf.client acceptBinaryData:data];
        };
        _usbReceiver.onDisconnected = ^{
            weakSelf.directUSB = NO;
            [weakSelf.client disconnect];
            if (![weakSelf.sourceKind isEqualToString:@"usb"]) return;
            [weakSelf.decoder reset]; [weakSelf.frameStore clear]; [weakSelf clearAudioSamples];
            [weakSelf applyConnection:ALConnectionSettings()];
        };
#endif
    }
    return self;
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    self.controls = ALCurrentControls() ?: ALDefaultControls(NSBundle.mainBundle.bundleIdentifier);
    __weak typeof(self) weakSelf = self;
    ALObserveControls(^(NSDictionary *controls) {
        weakSelf.controls = controls;
#ifdef APPLELIVE_STANDALONE
        [weakSelf configureAudioBridge];
#endif
        os_log(OS_LOG_DEFAULT, "[AppleLive] controls enabled=%d rotation=%d mirror=%d fill=%d camera=%d",
               [controls[@"enabled"] boolValue], [controls[@"rotation"] intValue],
               [controls[@"mirror"] boolValue], [controls[@"fill"] boolValue],
               [controls[@"cameraPortrait"] boolValue]);
    });
    ALInstallHooks();
#ifdef APPLELIVE_STANDALONE
    ALInstallPreviewHooks();
    ALInstallAudioUnitBridge();
#endif

#ifdef APPLELIVE_STANDALONE
    self.enabled = YES;
    self.audioRing.active = YES;
    self.unitAudioRing.active = YES;
#else
    NSDictionary *preferences = nil;
    NSArray<NSString *> *paths = @[
        @"/var/mobile/Library/Preferences/com.applelive.tweak.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.applelive.tweak.plist",
    ];
    for (NSString *path in paths) {
        preferences = [NSDictionary dictionaryWithContentsOfFile:path];
        if (preferences) break;
    }
    // Fresh rootless installs have no legacy configuration file. The panel's
    // controls own the user-facing switches; preserve explicit legacy opt-outs.
    self.enabled = preferences[@"enabled"] ? [preferences[@"enabled"] boolValue] : YES;
    self.audioRing.active = preferences[@"audioEnabled"] ? [preferences[@"audioEnabled"] boolValue] : YES;
#endif
    ALObserveConnection(^(NSDictionary *settings) { [weakSelf applyConnection:settings]; });
    NSDictionary *connection = ALConnectionSettings();
    [self applyConnection:connection];
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"mediaserverd"]) {
        ALPublishConnection(connection);
        self.statusTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(self.statusTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(self.statusTimer, ^{
            ALVirtualCamera *camera = weakSelf;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            BOOL usb = [camera.client.address containsString:@"127.0.0.1:"];
            ALPublishStreamStatus(camera.client.isConnected, usb,
                                  now - camera.lastVideoTime < 2, now - camera.lastAudioTime < 2);
        });
        dispatch_resume(self.statusTimer);
    }
}

- (void)applyConnection:(NSDictionary *)settings {
#ifdef APPLELIVE_STANDALONE
    if (![self.sourceKind isEqualToString:@"usb"]) return;
    self.connectionPaused = NO;
    [self configureAudioBridge];
    [self.client disconnect];
    [self.usbReceiver start];
    return;
#else
    NSArray *addresses = ALConnectionAddresses(settings);
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"mediaserverd"]) ALPersistConnection(settings);
    self.connectionPaused = [settings[@"paused"] boolValue];
    self.connectionAddresses = addresses;
    if (self.enabled && !self.connectionPaused && addresses.count) [self.client connectToAddresses:addresses];
    else [self.client disconnect];
    os_log(OS_LOG_DEFAULT, "[AppleLive] connection mode=%{public}@ addresses=%{public}@", settings[@"mode"], addresses);
#endif
}

- (NSDictionary *)streamStatus {
#ifdef APPLELIVE_STANDALONE
    if (self.directUSB) return @{@"connected": @YES, @"usb": @YES,
        @"video": @(CFAbsoluteTimeGetCurrent() - self.lastVideoTime < 2), @"audio": @(CFAbsoluteTimeGetCurrent() - self.lastAudioTime < 2)};
    if ([self.sourceKind isEqualToString:@"usb"]) {
        return @{@"connected": @NO, @"video": @NO, @"usb": @YES, @"audio": @NO};
    }
    CVPixelBufferRef frame = [self.frameStore copyLatestPixelBuffer];
    BOOL hasFrame = frame != NULL;
    if (frame) CVPixelBufferRelease(frame);
    return @{@"connected": @(hasFrame), @"video": @(hasFrame), @"usb": @NO,
             @"audio": @(CFAbsoluteTimeGetCurrent() - self.lastAudioTime < 2)};
#endif
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    return @{@"connected": @(self.client.isConnected),
             @"usb": @([self.client.address containsString:@"127.0.0.1:"]),
             @"video": @(now - self.lastVideoTime < 2),
             @"audio": @(now - self.lastAudioTime < 2)};
}

- (CMSampleBufferRef)replacementForVideoSample:(CMSampleBufferRef)original {
    if (!self.enabled || self.connectionPaused || ![self.controls[@"enabled"] boolValue]) return NULL;
    if (original && CMGetAttachment((CMAttachmentBearerRef)original,
                                    CFSTR("applelive_virtual"), NULL)) return NULL;
    if (original) {
        return [self renderVideoIntoSample:original] ? (CMSampleBufferRef)CFRetain(original) : NULL;
    }
    CVPixelBufferRef pixelBuffer = [self.frameStore copyLatestPixelBuffer];
    if (!pixelBuffer) return NULL;
    CMSampleBufferRef replacement = ALCreateVideoSample(pixelBuffer, original);
    CVPixelBufferRelease(pixelBuffer);
    return replacement;
}

- (BOOL)renderVideoIntoSample:(CMSampleBufferRef)sample {
    NSDictionary *controls = self.controls;
    if (!self.enabled || self.connectionPaused || ![controls[@"enabled"] boolValue] || !sample ||
        CMGetAttachment(sample, CFSTR("applelive_virtual"), NULL)) return NO;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) return NO;
    CVPixelBufferRef target = CMSampleBufferGetImageBuffer(sample);
    if (!target) return NO;
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(target);
    if (pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        pixelFormat != kCVPixelFormatType_32BGRA) return NO;
    CVPixelBufferRef incoming = [self.frameStore copyLatestPixelBuffer];
    if (!incoming) return NO;
    BOOL rendered = NO;
    @try {
        // Reuse the GPU context. This method can run on multiple camera queues.
        @synchronized (self) {
            if (!self.renderContext) {
                self.renderContext = ALCreateVideoRenderContext();
            }
        }
        CGFloat width = CVPixelBufferGetWidth(target);
        CGFloat height = CVPixelBufferGetHeight(target);
        CIImage *image = ALVideoImageFromPixelBuffer(incoming);
#ifdef APPLELIVE_STANDALONE
        if (self.sourceRotation) image = [image imageByApplyingTransform:CGAffineTransformMakeRotation(-(CGFloat)self.sourceRotation * M_PI_2)];
#endif
        CGRect inputBounds = image.extent;
        if ([controls[@"mirror"] boolValue]) {
            image = [image imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
        }
        // Stock Camera and live apps apply different preview orientations.
        // The foreground app publishes its own defaults and saved adjustments.
        if (!CMGetAttachment(sample, CFSTR("applelive_preview"), NULL) &&
            (inputBounds.size.width < inputBounds.size.height) != (width < height)) {
            image = [image imageByApplyingOrientation:[controls[@"cameraPortrait"] boolValue] ? 8 : 6];
        }
        NSUInteger turns = [controls[@"rotation"] unsignedIntegerValue] % 4;
        if (turns) image = [image imageByApplyingTransform:CGAffineTransformMakeRotation(-(CGFloat)turns * M_PI_2)];
        inputBounds = image.extent;
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
            -inputBounds.origin.x, -inputBounds.origin.y)];
        CGFloat scale = [controls[@"fill"] boolValue]
            ? MAX(width / inputBounds.size.width, height / inputBounds.size.height)
            : MIN(width / inputBounds.size.width, height / inputBounds.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
            (width - inputBounds.size.width * scale) / 2,
            (height - inputBounds.size.height * scale) / 2)];
        CGRect bounds = CGRectMake(0, 0, width, height);
        CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                         imageByCroppingToRect:bounds];
        image = [[image imageByCompositingOverImage:black] imageByCroppingToRect:bounds];
        ALRenderVideoImage(self.renderContext, image, target, bounds);
        CMSetAttachment(sample, CFSTR("applelive_virtual"), kCFBooleanTrue,
                        kCMAttachmentMode_ShouldPropagate);
        static uint64_t renders = 0;
        uint64_t count = __sync_add_and_fetch(&renders, 1);
        if (count == 1 || count % 300 == 0) {
            os_log(OS_LOG_DEFAULT, "[AppleLive] rendered frames=%llu source=%dx%d target=%dx%d format=%u",
                   count, (int)CVPixelBufferGetWidth(incoming), (int)CVPixelBufferGetHeight(incoming),
                   (int)width, (int)height, (unsigned)pixelFormat);
        }
        rendered = YES;
    } @catch (NSException *exception) {
        static uint64_t failures = 0;
        if (__sync_add_and_fetch(&failures, 1) <= 3) {
            os_log_error(OS_LOG_DEFAULT, "[AppleLive] frame render exception: %{public}@", exception);
        }
    }
    CVPixelBufferRelease(incoming);
    return rendered;
}

- (CMSampleBufferRef)replacementForAudioSample:(CMSampleBufferRef)original {
#ifdef APPLELIVE_STANDALONE
    NSDictionary *settings = self.controls;
    if (!self.enabled || self.connectionPaused || ![settings[@"enabled"] boolValue] ||
        ![settings[@"audio"] boolValue] || !original ||
        CMGetAttachment(original, CFSTR("applelive_virtual"), NULL)) return NULL;
    return ALCreateInjectedAudio(original, self.audioRing, [settings[@"muted"] boolValue]);
#else
    NSDictionary *controls = self.controls;
    if (!self.enabled || self.connectionPaused || ![controls[@"enabled"] boolValue] || ![controls[@"audio"] boolValue] ||
        !self.audioRing.isActive || !original) return NULL;
    if (CMGetAttachment((CMAttachmentBearerRef)original,
                        CFSTR("applelive_virtual"), NULL)) return NULL;
    CMAudioFormatDescriptionRef originalFormat = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(original);
    const AudioStreamBasicDescription *sourceASBD = originalFormat
        ? CMAudioFormatDescriptionGetStreamBasicDescription(originalFormat) : NULL;
    if (!sourceASBD) return NULL;
    NSUInteger samples = CMSampleBufferGetNumSamples(original);
    NSUInteger channels = sourceASBD->mChannelsPerFrame ?: 1;
    if (!samples) return NULL;

    NSMutableData *floatData = [NSMutableData dataWithLength:samples * channels * sizeof(float)];
    if (![self.audioRing popSamples:floatData.mutableBytes count:samples
                            channels:channels sampleRate:sourceASBD->mSampleRate]) return NULL;

    BOOL isFloat = (sourceASBD->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    NSUInteger bytesPerSample = sourceASBD->mBytesPerFrame / channels;
    NSMutableData *outputData = [NSMutableData dataWithLength:samples * sourceASBD->mBytesPerFrame];
    const float *input = floatData.bytes;
    if (isFloat && bytesPerSample >= sizeof(float)) {
        memcpy(outputData.mutableBytes, input, MIN(outputData.length, floatData.length));
    } else if (bytesPerSample == sizeof(int16_t)) {
        int16_t *output = outputData.mutableBytes;
        for (NSUInteger i = 0; i < samples * channels; i++) {
            float value = MAX(-1.0f, MIN(1.0f, input[i]));
            output[i] = (int16_t)lrintf(value * 32767.0f);
        }
    } else {
        return NULL;
    }

    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, outputData.length,
                                           kCFAllocatorDefault, NULL, 0, outputData.length,
                                           kCMBlockBufferAssureMemoryNowFlag, &block) != kCMBlockBufferNoErr) return NULL;
    CMBlockBufferReplaceDataBytes(outputData.bytes, block, 0, outputData.length);
    CMAudioFormatDescriptionRef format = NULL;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, sourceASBD, 0, NULL, 0, NULL,
                                        NULL, &format) != noErr) {
        CFRelease(block);
        return NULL;
    }
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration = CMTimeMake(1, (int32_t)sourceASBD->mSampleRate);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }
    const size_t sampleSize = sourceASBD->mBytesPerFrame;
    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, samples, 1, &timing,
                              1, &sampleSize, &result);
    CFRelease(format);
    CFRelease(block);
    if (result) {
        CMSetAttachment((CMAttachmentBearerRef)result, CFSTR("applelive_virtual"),
                        kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    }
    return result;
#endif
}

#ifdef APPLELIVE_STANDALONE
- (void)selectSource:(NSString *)kind URL:(NSURL *)url {
    [self.mediaPlayer stop];
    self.sourceKind = kind;
    self.sourceURL = url;
    self.sourceRotation = 0;
    self.directUSB = NO;
    [self.usbReceiver stop];
    self.connectionPaused = NO;
    [self configureAudioBridge];
    [self.client disconnect];
    [self.decoder reset];
    [self.frameStore clear];
    [self clearAudioSamples];
    self.lastVideoTime = self.lastAudioTime = 0;
    // Live demuxers can deliver decoded frames in short bursts. Keep the last
    // network frame visible across that jitter; onReset clears it on a real
    // disconnect or failed reconnect.
    self.frameStore.holdsFrame = [kind isEqualToString:@"local"] || [kind isEqualToString:@"network"];
    if ([kind isEqualToString:@"usb"]) [self applyConnection:ALConnectionSettings()];
    else if (url) {
        UIImage *still = url.isFileURL ? [UIImage imageWithContentsOfFile:url.path] : nil;
        if (still.CGImage) {
            static const int orientations[] = {1, 3, 8, 6, 2, 4, 5, 7};
            CIImage *image = [[CIImage imageWithCGImage:still.CGImage] imageByApplyingOrientation:orientations[still.imageOrientation]];
            CGFloat scale = MIN(1, 1920 / MAX(image.extent.size.width, image.extent.size.height));
            image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
            CVPixelBufferRef frame = NULL;
            NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
            if (CVPixelBufferCreate(NULL, ceil(image.extent.size.width), ceil(image.extent.size.height), kCVPixelFormatType_32BGRA,
                    (__bridge CFDictionaryRef)attributes, &frame) == kCVReturnSuccess) {
                CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
                [context render:image toCVPixelBuffer:frame];
                [self.frameStore storePixelBuffer:frame sequence:1];
                CVPixelBufferRelease(frame); self.lastVideoTime = CFAbsoluteTimeGetCurrent();
            }
        } else [self.mediaPlayer playURL:url];
    }
}
- (NSDictionary *)mediaStatus { return self.mediaPlayer.status; }
- (void)configureAudioBridge {
    ALConfigureAudioUnitBridge(self.unitAudioRing,
        self.enabled && !self.connectionPaused && ![self.sourceKind isEqualToString:@"none"] &&
        [self.controls[@"enabled"] boolValue] && [self.controls[@"audio"] boolValue], [self.controls[@"muted"] boolValue]);
}
- (void)setMediaPaused:(BOOL)paused {
    self.mediaPlayer.paused = paused;
    [self clearAudioSamples];
}
- (void)seekMedia:(NSTimeInterval)seconds { [self.mediaPlayer seek:seconds]; }
- (CVPixelBufferRef)copyPreviewPixelBuffer:(CGSize)size {
    if (!self.enabled || self.connectionPaused || ![self.controls[@"enabled"] boolValue]) return NULL;
    CVPixelBufferRef latest = [self.frameStore copyLatestPixelBuffer];
    if (!latest) return NULL;
    if (size.width < 1 || size.height < 1) {
        BOOL rotated = (self.sourceRotation + [self.controls[@"rotation"] integerValue]) % 2;
        size = CGSizeMake(rotated ? CVPixelBufferGetHeight(latest) : CVPixelBufferGetWidth(latest),
                          rotated ? CVPixelBufferGetWidth(latest) : CVPixelBufferGetHeight(latest));
    }
    CVPixelBufferRelease(latest);
    CVPixelBufferRef target = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (CVPixelBufferCreate(NULL, (size_t)size.width, (size_t)size.height, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &target) != kCVReturnSuccess) return NULL;
    CMSampleBufferRef sample = ALCreateVideoSample(target, NULL);
    if (!sample) { CVPixelBufferRelease(target); return NULL; }
    CMRemoveAttachment(sample, CFSTR("applelive_virtual"));
    CMSetAttachment(sample, CFSTR("applelive_preview"), kCFBooleanTrue, kCMAttachmentMode_ShouldNotPropagate);
    BOOL rendered = [self renderVideoIntoSample:sample];
    CFRelease(sample);
    if (!rendered) { CVPixelBufferRelease(target); return NULL; }
    return target;
}
- (NSData *)sourceJPEG {
    CVPixelBufferRef frame = [self copyPreviewPixelBuffer:CGSizeZero];
    if (!frame) return nil;
    CIImage *image = ALVideoImageFromPixelBuffer(frame);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSData *jpeg = [self.renderContext JPEGRepresentationOfImage:image colorSpace:colorSpace
        options:@{(id)kCGImageDestinationLossyCompressionQuality: @0.95}];
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferRelease(frame);
    return jpeg;
}
#endif

@end
