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
    BOOL hd = CVPixelBufferGetWidth(pixelBuffer) >= 1280 || CVPixelBufferGetHeight(pixelBuffer) > 576;
    CFStringRef primaries = hd ? kCVImageBufferColorPrimaries_ITU_R_709_2
                               : kCVImageBufferColorPrimaries_SMPTE_C;
    CFStringRef matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
                            : kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    if (!CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, NULL))
        ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries);
    if (!CVBufferGetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, NULL))
        ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferTransferFunctionKey,
                                 kCVImageBufferTransferFunction_ITU_R_709_2);
    if (!CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL))
        ALSetAttachmentIfPresent(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix);
}

void ALRenderVideoImage(CIContext *context, CIImage *image,
                        CVPixelBufferRef target, CGRect bounds) {
    if (!context || !image || !target) return;
    ALSetVideoColorAttachments(target,
                               kCVImageBufferColorPrimaries_ITU_R_709_2,
                               kCVImageBufferTransferFunction_ITU_R_709_2,
                               kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    [context render:image toCVPixelBuffer:target bounds:bounds
          colorSpace:ALBT709ColorSpace()];
}
