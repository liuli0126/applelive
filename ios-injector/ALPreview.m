#import "ALPreview.h"
#import "ALVirtualCamera.h"
#import "ALFrameStore.h"
#import "ALPreviewRenderer.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static const void *kALPreviewLayer = &kALPreviewLayer;
static NSHashTable *gALPreviewLayers;
static NSHashTable *gALPreviewViews;
static void (*gALPreviewLayout)(id, SEL);
static void (*gALPreviewSetSession)(id, SEL, AVCaptureSession *);
static NSData *(*gALStillJPEG)(id, SEL, CMSampleBufferRef);
static NSData *(*gALPhotoData)(id, SEL);

static void ALReplaceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = class_getMethodImplementation(cls, selector);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static void ALPaintPreview(AVSampleBufferDisplayLayer *layer, CGSize size, BOOL active) {
    ALVirtualCamera *camera = [ALVirtualCamera sharedInstance];
    active = active && [camera isVideoReplacementActive];
    uint64_t generation = camera.frameStore.generation;
    if (!active || size.width < 1 || size.height < 1) {
        ALUpdatePreviewLayer(layer, NULL, generation, active); return;
    }
    CGFloat scale = MIN(1, 720 / MAX(size.width, size.height));
    CVPixelBufferRef pixel = [camera copyPreviewPixelBuffer:CGSizeMake(ceil(size.width * scale), ceil(size.height * scale))];
    ALUpdatePreviewLayer(layer, pixel, generation, active);
    if (pixel) CVPixelBufferRelease(pixel);
}

@interface ALPreviewTicker : NSObject
- (void)tick;
@end
@implementation ALPreviewTicker
- (void)tick {
    BOOL foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    for (AVCaptureVideoPreviewLayer *preview in gALPreviewLayers.allObjects) {
        AVSampleBufferDisplayLayer *overlay = objc_getAssociatedObject(preview, kALPreviewLayer);
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        if (preview.bounds.size.width > 0 && preview.bounds.size.height > 0) overlay.frame = preview.bounds;
        [CATransaction commit];
        // A capture-session restart is not an explicit request to reveal its
        // physical camera. The selected source controls overlay visibility.
        ALPaintPreview(overlay, preview.bounds.size, foreground && preview.superlayer != nil);
    }
    for (ALPreviewView *view in gALPreviewViews.allObjects)
        ALPaintPreview((AVSampleBufferDisplayLayer *)view.layer, view.bounds.size, foreground && view.window != nil && !view.hidden);
}
@end

static void ALTrackPreview(AVCaptureVideoPreviewLayer *preview) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ ALTrackPreview(preview); }); return; }
    if (!preview.session) return;
    AVSampleBufferDisplayLayer *overlay = objc_getAssociatedObject(preview, kALPreviewLayer);
    if (!overlay) {
        overlay = [AVSampleBufferDisplayLayer layer];
        overlay.videoGravity = AVLayerVideoGravityResize;
        overlay.backgroundColor = UIColor.blackColor.CGColor;
        overlay.hidden = YES;
        objc_setAssociatedObject(preview, kALPreviewLayer, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [preview addSublayer:overlay]; [gALPreviewLayers addObject:preview];
    }
    if (preview.bounds.size.width > 0 && preview.bounds.size.height > 0) overlay.frame = preview.bounds;
}
static void ALPreviewLayout(id self, SEL selector) {
    if (gALPreviewLayout) gALPreviewLayout(self, selector);
    ALTrackPreview(self);
}
static void ALPreviewSetSession(id self, SEL selector, AVCaptureSession *session) {
    if (gALPreviewSetSession) gALPreviewSetSession(self, selector, session);
    ALTrackPreview(self);
}
static NSData *ALStillJPEG(id self, SEL selector, CMSampleBufferRef sample) {
    NSData *replacement = [[ALVirtualCamera sharedInstance] sourceJPEG];
    return replacement ?: (gALStillJPEG ? gALStillJPEG(self, selector, sample) : nil);
}
static NSData *ALPhotoData(id self, SEL selector) {
    NSData *replacement = [[ALVirtualCamera sharedInstance] sourceJPEG];
    return replacement ?: (gALPhotoData ? gALPhotoData(self, selector) : nil);
}
@implementation ALPreviewView
+ (Class)layerClass { return AVSampleBufferDisplayLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        ((AVSampleBufferDisplayLayer *)self.layer).videoGravity = AVLayerVideoGravityResize;
        [gALPreviewViews addObject:self];
    }
    return self;
}
@end
void ALInstallPreviewHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gALPreviewLayers = [NSHashTable weakObjectsHashTable];
        gALPreviewViews = [NSHashTable weakObjectsHashTable];
        ALReplaceMethod(AVCaptureVideoPreviewLayer.class, @selector(layoutSublayers), (IMP)ALPreviewLayout, (IMP *)&gALPreviewLayout);
        ALReplaceMethod(AVCaptureVideoPreviewLayer.class, @selector(setSession:), (IMP)ALPreviewSetSession, (IMP *)&gALPreviewSetSession);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        ALReplaceMethod(object_getClass(AVCaptureStillImageOutput.class), @selector(jpegStillImageNSDataRepresentation:), (IMP)ALStillJPEG, (IMP *)&gALStillJPEG);
#pragma clang diagnostic pop
        ALReplaceMethod(AVCapturePhoto.class, @selector(fileDataRepresentation), (IMP)ALPhotoData, (IMP *)&gALPhotoData);
        dispatch_async(dispatch_get_main_queue(), ^{
            static ALPreviewTicker *ticker; ticker = [ALPreviewTicker new];
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick)];
            link.preferredFramesPerSecond = 15;
            [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        });
    });
}
