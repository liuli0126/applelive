#import "ALUVCFrame.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <string.h>

static uint8_t ALByte(int value) { return (uint8_t)MAX(0, MIN(255, value)); }

CVPixelBufferRef ALCopyUVCFrame(const void *bytes, size_t length, size_t width,
                              size_t height, size_t stride, BOOL jpeg, BOOL uyvy) {
    if (!bytes || !length || length > 16 * 1024 * 1024 || width < 2 || height < 2 ||
        width > 1920 || height > 1920 || width * height > 1920 * 1080) return NULL;
    CGImageRef image = NULL;
    if (jpeg) {
        if (length < 4 || ((const uint8_t *)bytes)[0] != 0xff || ((const uint8_t *)bytes)[1] != 0xd8) return NULL;
        CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, bytes, length, kCFAllocatorNull);
        if (!data) return NULL;
        CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
        CFRelease(data);
        if (!source) return NULL;
        NSDictionary *options = @{(id)kCGImageSourceShouldCache: @NO};
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        if ([properties[(id)kCGImagePropertyPixelWidth] unsignedLongLongValue] == width &&
            [properties[(id)kCGImagePropertyPixelHeight] unsignedLongLongValue] == height)
            image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (!image || CGImageGetWidth(image) != width || CGImageGetHeight(image) != height) {
            if (image) CGImageRelease(image);
            return NULL;
        }
    } else {
        if (width % 2) return NULL;
        if (!stride) stride = width * 2;
        if (stride < width * 2 || stride > 16 * 1024 * 1024 ||
            (height - 1) > (SIZE_MAX - width * 2) / stride ||
            length < (height - 1) * stride + width * 2) return NULL;
    }
    CVPixelBufferRef output = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &output) != kCVReturnSuccess) {
        if (image) CGImageRelease(image);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(output, 0) != kCVReturnSuccess) {
        if (image) CGImageRelease(image);
        CVPixelBufferRelease(output); return NULL;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    BOOL valid = YES;
    uint8_t *dest = CVPixelBufferGetBaseAddress(output);
    size_t destStride = CVPixelBufferGetBytesPerRow(output);
    if (image) {
        CGContextRef context = CGBitmapContextCreate(dest, width, height, 8, destStride,
            space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        if (context) {
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
            CGContextRelease(context);
        } else valid = NO;
        CGImageRelease(image);
    } else {
        // Baseline UVC YUY2/UYVY uses limited-range BT.601. Keep output owned,
        // honor per-row padding, and never read a truncated packet.
        for (size_t y = 0; y < height; y++) {
            const uint8_t *src = (const uint8_t *)bytes + y * stride;
            uint8_t *row = dest + y * destStride;
            for (size_t x = 0; x < width; x += 2, src += 4) {
                int u = src[uyvy ? 0 : 1] - 128, v = src[uyvy ? 2 : 3] - 128;
                for (int i = 0; i < 2; i++) {
                    int c = MAX(0, src[(uyvy ? 1 : 0) + 2 * i] - 16) * 298;
                    row[(x+i)*4] = ALByte((c + 516*u + 128) >> 8);
                    row[(x+i)*4+1] = ALByte((c - 100*u - 208*v + 128) >> 8);
                    row[(x+i)*4+2] = ALByte((c + 409*v + 128) >> 8);
                    row[(x+i)*4+3] = 255;
                }
            }
        }
    }
    if (space) {
        CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
        CGColorSpaceRelease(space);
    }
    CVPixelBufferUnlockBaseAddress(output, 0);
    if (!valid) { CVPixelBufferRelease(output); return NULL; }
    return output;
}
