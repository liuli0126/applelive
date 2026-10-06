#import "ALColorPipeline.h"
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <math.h>
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

static CVPixelBufferRef createBuffer(OSType format) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    require(CVPixelBufferCreate(NULL, 16, 16, format,
            (__bridge CFDictionaryRef)attributes, &buffer) == kCVReturnSuccess,
            "create camera-format buffer");
    return buffer;
}

static void fillYUV(CVPixelBufferRef buffer, int y, int cb, int cr) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    for (int row = 0; row < 16; row++)
        memset(luma + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), y, 16);
    for (int row = 0; row < 8; row++) for (int x = 0; x < 16; x += 2) {
        uint8_t *p = uv + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x;
        p[0] = cb; p[1] = cr;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static void testCameraYUV(OSType targetFormat, BOOL matrix601) {
    CVPixelBufferRef source = createVideoRangeBuffer();
    CVPixelBufferRef target = createBuffer(targetFormat);
    CFStringRef matrix = matrix601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
                                  : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    ALSetVideoColorAttachments(source, kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    ALSetVideoColorAttachments(target, kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunction_ITU_R_709_2, matrix);
    CMVideoFormatDescriptionRef cameraFormat = NULL;
    require(CMVideoFormatDescriptionCreateForImageBuffer(NULL, target, &cameraFormat) == noErr,
            "capture original immutable camera format");
    const int patches[][3] = {{16,128,128}, {64,128,128}, {126,128,128},
        {192,128,128}, {235,128,128}, {81,110,180}, {145,95,75}, {65,190,115}};
    CIContext *context = ALCreateVideoRenderContext();
    BOOL full = targetFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    for (size_t i = 0; i < sizeof(patches)/sizeof(patches[0]); i++) {
        int y = patches[i][0], cb = patches[i][1], cr = patches[i][2];
        fillYUV(source, y, cb, cr);
        ALRenderVideoImage(context, ALVideoImageFromPixelBuffer(source), target, CGRectMake(0,0,16,16));
        require(CMVideoFormatDescriptionMatchesImageBuffer(cameraFormat, target),
                "rendered pixels must still match the original camera sample format");
        // Independent Rec.709 -> RGB -> target matrix/range reference.
        double l = (y - 16) / 219.0, u = (cb - 128) / 224.0, v = (cr - 128) / 224.0;
        double r = l + 1.5748*v, b = l + 1.8556*u;
        double g = (l - .2126*r - .0722*b) / .7152;
        double kr = matrix601 ? .299 : .2126, kb = matrix601 ? .114 : .0722;
        double outY = kr*r + (1-kr-kb)*g + kb*b;
        int expected[] = {(int)lround((full ? 0 : 16) + (full ? 255 : 219)*outY),
            (int)lround(128 + (full ? 255 : 224)*(b-outY)/(2*(1-kb))),
            (int)lround(128 + (full ? 255 : 224)*(r-outY)/(2*(1-kr)))};
        CVPixelBufferLockBaseAddress(target, kCVPixelBufferLock_ReadOnly);
        uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(target,0);
        uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(target,1);
        int output[] = {yp[4*CVPixelBufferGetBytesPerRowOfPlane(target,0)+4],
            uv[2*CVPixelBufferGetBytesPerRowOfPlane(target,1)+4],
            uv[2*CVPixelBufferGetBytesPerRowOfPlane(target,1)+5]};
        CVPixelBufferUnlockBaseAddress(target, kCVPixelBufferLock_ReadOnly);
        fprintf(stderr,"camera %s/%s patch %zu expected=%d,%d,%d output=%d,%d,%d\n",
            full ? "full" : "limited", matrix601 ? "601" : "709", i,
            expected[0],expected[1],expected[2],output[0],output[1],output[2]);
        for (int c=0;c<3;c++) require(abs(output[c]-expected[c])<=4,
                "camera color patch must preserve level, chroma and range");
    }
    CFRelease(cameraFormat); CVPixelBufferRelease(target); CVPixelBufferRelease(source);
}

static void testCameraBGRA(void) {
    CVPixelBufferRef source = createVideoRangeBuffer();
    CVPixelBufferRef target = createBuffer(kCVPixelFormatType_32BGRA);
    ALSetVideoColorAttachments(source, kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    ALSetVideoColorAttachments(target, kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunction_sRGB, NULL);
    CMVideoFormatDescriptionRef cameraFormat = NULL;
    require(CMVideoFormatDescriptionCreateForImageBuffer(NULL,target,&cameraFormat)==noErr,"BGRA format");
    fillYUV(source,16,128,128);
    ALRenderVideoImage(ALCreateVideoRenderContext(),ALVideoImageFromPixelBuffer(source),target,CGRectMake(0,0,16,16));
    require(CMVideoFormatDescriptionMatchesImageBuffer(cameraFormat,target),"BGRA sample color metadata preserved");
    CVPixelBufferLockBaseAddress(target,kCVPixelBufferLock_ReadOnly);
    const uint8_t *p = CVPixelBufferGetBaseAddress(target);
    require(p[0]<=2 && p[1]<=2 && p[2]<=2 && p[3]==255,"BGRA black stays black and opaque");
    CVPixelBufferUnlockBaseAddress(target,kCVPixelBufferLock_ReadOnly);
    CFRelease(cameraFormat); CVPixelBufferRelease(target); CVPixelBufferRelease(source);
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
        ALSetVideoColorAttachments(target,
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
        testCameraYUV(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NO);
        testCameraYUV(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NO);
        testCameraYUV(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, YES);
        testCameraBGRA();
        puts("BT.709 video-range color pipeline passed");
    }
    return 0;
}
