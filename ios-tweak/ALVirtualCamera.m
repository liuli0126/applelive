#import "ALVirtualCamera.h"
#import "ALAudioRing.h"
#import "ALFrameStore.h"
#import "ALStreamClient.h"
#import "ALVideoDecoder.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <math.h>

static const void *kALVideoProxyKey = &kALVideoProxyKey;
static const void *kALAudioProxyKey = &kALAudioProxyKey;
static BOOL gALHooksInstalled = NO;
static CMSampleBufferRef (*gOriginalBWCopyNext)(id, SEL) = NULL;
static void (*gOriginalVideoSetDelegate)(id, SEL, id, dispatch_queue_t) = NULL;
static void (*gOriginalAudioSetDelegate)(id, SEL, id, dispatch_queue_t) = NULL;

@interface ALVirtualCamera ()
@property(nonatomic, readwrite) ALFrameStore *frameStore;
@property(nonatomic, readwrite) ALAudioRing *audioRing;
@property(nonatomic) ALStreamClient *client;
@property(nonatomic) ALVideoDecoder *decoder;
@property(nonatomic) BOOL started;
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
    if (bwNodeOutput && class_getInstanceMethod(bwNodeOutput, @selector(copyNextSampleBuffer))) {
        MSHookMessageEx(bwNodeOutput, @selector(copyNextSampleBuffer),
                        (IMP)ALHookBWCopyNext, (IMP *)&gOriginalBWCopyNext);
    }

    Class videoOutput = [AVCaptureVideoDataOutput class];
    if (videoOutput) {
        MSHookMessageEx(videoOutput, @selector(setSampleBufferDelegate:queue:),
                        (IMP)ALHookVideoSetDelegate, (IMP *)&gOriginalVideoSetDelegate);
    }
    Class audioOutput = [AVCaptureAudioDataOutput class];
    if (audioOutput) {
        MSHookMessageEx(audioOutput, @selector(setSampleBufferDelegate:queue:),
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

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameStore = [[ALFrameStore alloc] init];
        _audioRing = [[ALAudioRing alloc] init];
        _client = [[ALStreamClient alloc] init];
        _decoder = [[ALVideoDecoder alloc] init];
        __weak typeof(self) weakSelf = self;
        _decoder.onFrame = ^(CVPixelBufferRef pixelBuffer, uint32_t sequence) {
            [weakSelf.frameStore storePixelBuffer:pixelBuffer sequence:sequence];
        };
        _client.onVideoNAL = ^(NSData *nal, uint32_t sequence, uint32_t flags,
                               uint32_t width, uint32_t height) {
            [weakSelf.decoder decodeNAL:nal sequence:sequence];
            (void)flags;
            (void)width;
            (void)height;
        };
        _client.onAudioPCM = ^(const float *samples, NSUInteger count,
                               uint32_t channels, double rate) {
            [weakSelf.audioRing pushSamples:samples count:count channels:channels sampleRate:rate];
        };
    }
    return self;
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    ALInstallHooks();

    NSDictionary *preferences = nil;
    NSArray<NSString *> *paths = @[
        @"/var/mobile/Library/Preferences/com.applelive.tweak.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.applelive.tweak.plist",
    ];
    for (NSString *path in paths) {
        preferences = [NSDictionary dictionaryWithContentsOfFile:path];
        if (preferences) break;
    }
    self.enabled = [preferences[@"enabled"] boolValue];
    NSString *server = [preferences[@"server"] isKindOfClass:[NSString class]] ? preferences[@"server"] : nil;
    self.audioRing.active = [preferences[@"audioEnabled"] boolValue];
    if (self.enabled && server.length) {
        [self.client connectToAddress:server];
        os_log(OS_LOG_DEFAULT, "[AppleLive] connecting to %{public}@", server);
    } else {
        os_log(OS_LOG_DEFAULT, "[AppleLive] disabled or server not configured");
    }
}

- (CMSampleBufferRef)replacementForVideoSample:(CMSampleBufferRef)original {
    if (!self.enabled) return NULL;
    if (original && CMGetAttachment((CMAttachmentBearerRef)original,
                                    CFSTR("applelive_virtual"), NULL)) return NULL;
    CVPixelBufferRef pixelBuffer = [self.frameStore copyLatestPixelBuffer];
    if (!pixelBuffer) return NULL;
    CMSampleBufferRef replacement = ALCreateVideoSample(pixelBuffer, original);
    CVPixelBufferRelease(pixelBuffer);
    return replacement;
}

- (CMSampleBufferRef)replacementForAudioSample:(CMSampleBufferRef)original {
    if (!self.enabled || !self.audioRing.isActive || !original) return NULL;
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
}

@end
