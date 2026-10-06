#import "ALColorPipeline.h"

CGColorSpaceRef ALBT709ColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
        if (!colorSpace) colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

static CGColorSpaceRef ALSRGBColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return colorSpace;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CFTypeRef ALVideoColorAttachment(CVPixelBufferRef pixelBuffer, CFStringRef key) {
    return CVBufferGetAttachment(pixelBuffer, key, NULL);
}

static CGColorSpaceRef ALCopyVideoColorSpace(CVPixelBufferRef pixelBuffer) {
    // Let CoreVideo interpret the actual primaries/transfer (including sRGB
    // and P3 camera buffers). Treating every non-sRGB frame as 709 changes
    // the colors before it ever reaches the app.
    CFDictionaryRef attachments = CVBufferGetAttachments(pixelBuffer, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRef space = attachments ? CVImageBufferCreateColorSpaceFromAttachments(attachments) : NULL;
    if (space) return space;
    CFTypeRef transfer = ALVideoColorAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey);
    BOOL rgb = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA;
    return CGColorSpaceRetain((rgb && !transfer) ||
        (transfer && CFEqual(transfer, kCVImageBufferTransferFunction_sRGB))
        ? ALSRGBColorSpace() : ALBT709ColorSpace());
}
#pragma clang diagnostic pop

CIImage *ALVideoImageFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return nil;
    CGColorSpaceRef sourceColorSpace = ALCopyVideoColorSpace(pixelBuffer);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer options:@{
        kCIImageColorSpace: (__bridge id)sourceColorSpace,
    }];
    CGColorSpaceRelease(sourceColorSpace);
    return image;
}

CIContext *ALCreateVideoRenderContext(void) {
    CGColorSpaceRef colorSpace = ALBT709ColorSpace();
    return [CIContext contextWithOptions:@{
        kCIContextUseSoftwareRenderer: @NO,
        kCIContextCacheIntermediates: @NO,
        kCIContextWorkingColorSpace: (__bridge id)colorSpace,
        kCIContextOutputColorSpace: (__bridge id)colorSpace,
    }];
}

static void ALSetAttachmentIfPresent(CVPixelBufferRef pixelBuffer,
                                     CFStringRef key, CFStringRef value) {
    if (value) CVBufferSetAttachment(pixelBuffer, key, value,
                                     kCVAttachmentMode_ShouldPropagate);
}

void ALSetVideoColorAttachments(CVPixelBufferRef pixelBuffer,
                                CFStringRef primaries,
                                CFStringRef transferFunction,
                                CFStringRef yCbCrMatrix) {
    if (!pixelBuffer) return;
    ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries);
    ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferTransferFunctionKey, transferFunction);
    ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferYCbCrMatrixKey, yCbCrMatrix);
}

void ALSetDefaultVideoColorAttachments(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return;
    BOOL rgb = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA;
    BOOL hd = CVPixelBufferGetWidth(pixelBuffer) >= 1280 || CVPixelBufferGetHeight(pixelBuffer) > 576;
    CFStringRef primaries = hd || rgb ? kCVImageBufferColorPrimaries_ITU_R_709_2
                               : kCVImageBufferColorPrimaries_SMPTE_C;
    CFStringRef matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
                            : kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    if (!ALVideoColorAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey))
        ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries);
    if (!ALVideoColorAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey))
        ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferTransferFunctionKey,
                                 rgb ? kCVImageBufferTransferFunction_sRGB
                                     : kCVImageBufferTransferFunction_ITU_R_709_2);
    if (!rgb && !ALVideoColorAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey))
        ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix);
}

void ALRenderVideoImage(CIContext *context, CIImage *image,
                        CVPixelBufferRef target, CGRect bounds) {
    if (!context || !image || !target) return;
    // The app still owns the original CMSampleBuffer and its immutable format
    // description. Convert into that camera's color space/range; relabeling
    // the pixels as 709 leaves the app interpreting them with stale metadata.
    // CoreImage uses the destination's 420v/420f format for range conversion
    // and its YCbCr matrix for the RGB -> YUV step. Do not replace either.
    CGColorSpaceRef targetSpace = ALCopyVideoColorSpace(target);
    [context render:image toCVPixelBuffer:target bounds:bounds
          colorSpace:targetSpace];
    CGColorSpaceRelease(targetSpace);
}
