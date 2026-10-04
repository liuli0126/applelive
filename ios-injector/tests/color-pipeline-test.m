#import "ALColorPipeline.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}

static CVPixelBufferRef createVideoRangeBuffer(void) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    require(CVPixelBufferCreate(NULL, 16, 16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attributes, &buffer) == kCVReturnSuccess,
            "create video-range pixel buffer");
    return buffer;
}

int main(void) {
    @autoreleasepool {
        CVPixelBufferRef source = createVideoRangeBuffer();
        CVPixelBufferRef target = createVideoRangeBuffer();
        CVPixelBufferLockBaseAddress(source, 0);
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(source, 0);
        size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0);
        uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(source, 1);
        size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1);
        for (size_t y = 0; y < 16; y++) memset(luma + y * lumaStride, y < 8 ? 64 : 192, 16);
        for (size_t y = 0; y < 8; y++) memset(chroma + y * chromaStride, 128, 16);
        CVPixelBufferUnlockBaseAddress(source, 0);
        ALSetVideoColorAttachments(source,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2);

        CIContext *context = ALCreateVideoRenderContext();
        CIImage *image = ALVideoImageFromPixelBuffer(source);
        ALRenderVideoImage(context, image, target, CGRectMake(0, 0, 16, 16));

        require(CFEqual(CVBufferGetAttachment(target, kCVImageBufferColorPrimariesKey, NULL),
                        kCVImageBufferColorPrimaries_ITU_R_709_2), "BT.709 primaries propagate");
        require(CFEqual(CVBufferGetAttachment(target, kCVImageBufferTransferFunctionKey, NULL),
                        kCVImageBufferTransferFunction_ITU_R_709_2), "BT.709 transfer propagates");
        require(CFEqual(CVBufferGetAttachment(target, kCVImageBufferYCbCrMatrixKey, NULL),
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2), "BT.709 matrix propagates");
        CVPixelBufferLockBaseAddress(target, kCVPixelBufferLock_ReadOnly);
        const uint8_t *output = CVPixelBufferGetBaseAddressOfPlane(target, 0);
        size_t outputStride = CVPixelBufferGetBytesPerRowOfPlane(target, 0);
        int dark = output[2 * outputStride + 2];
        int bright = output[12 * outputStride + 2];
        CVPixelBufferUnlockBaseAddress(target, kCVPixelBufferLock_ReadOnly);
        fprintf(stderr, "video-range luma input=64,192 output=%d,%d\n", dark, bright);
        require(abs(dark - 64) <= 4, "video-range dark luma preserved");
        require(abs(bright - 192) <= 4, "video-range bright luma preserved");
        CVPixelBufferRelease(target); CVPixelBufferRelease(source);
        puts("BT.709 video-range color pipeline passed");
    }
    return 0;
}
