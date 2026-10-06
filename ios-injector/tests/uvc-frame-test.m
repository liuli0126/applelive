#import "ALUVCFrame.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdlib.h>
#include <string.h>

static void check(BOOL passed, const char *message) {
    if (!passed) { fprintf(stderr, "FAIL %s\n", message); exit(1); }
}
static void raw(BOOL uyvy) {
    uint8_t input[16] = {16,128,235,128, 7,7,7,7, 81,90,81,240, 9,9,9,9};
    if (uyvy) {
        uint8_t reordered[16] = {128,16,128,235,7,7,7,7,90,81,240,81,9,9,9,9};
        memcpy(input,reordered,sizeof(input));
    }
    CVPixelBufferRef pixel = ALCopyUVCFrame(input,12,2,2,8,NO,uyvy);
    check(pixel != NULL,"padded raw frame accepted");
    memset(input,0,sizeof(input)); // The output must not alias libuvc memory.
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    uint8_t *bytes = CVPixelBufferGetBaseAddress(pixel);
    size_t row = CVPixelBufferGetBytesPerRow(pixel);
    check(bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 255,"limited black");
    check(bytes[4] == 255 && bytes[5] == 255 && bytes[6] == 255,"limited white");
    check(bytes[row] <= 2 && bytes[row+1] <= 2 && bytes[row+2] >= 253,"601 red with row padding");
    check(CVBufferGetAttachment(pixel,kCVImageBufferCGColorSpaceKey,NULL) != NULL,"RGB color space");
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pixel);
    check(ALCopyUVCFrame(input,11,2,2,8,NO,uyvy) == NULL,"reject truncated last row");
    check(ALCopyUVCFrame(input,16,3,2,8,NO,uyvy) == NULL,"reject odd raw width");
    check(ALCopyUVCFrame(input,16,2,2,3,NO,uyvy) == NULL,"reject short row");
}
static void jpeg(void) {
    const size_t width = 32, height = 32;
    uint8_t pixels[width*height*4];
    for (size_t y=0;y<height;y++) for (size_t x=0;x<width;x++) {
        uint8_t *p = pixels+(y*width+x)*4;
        p[0] = p[1] = p[2] = y < height/2 ? 30 : 220; p[3]=255;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(pixels,width,height,8,width*4,space,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGImageRef source = CGBitmapContextCreateImage(bitmap);
    NSMutableData *data = [NSMutableData new];
    CGImageDestinationRef encoder = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,NULL);
    CGImageDestinationAddImage(encoder,source,(__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality:@1});
    check(CGImageDestinationFinalize(encoder),"JPEG fixture encode");
    CVPixelBufferRef pixel = ALCopyUVCFrame(data.bytes,data.length,width,height,0,YES,NO);
    check(pixel != NULL,"MJPEG decode");
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    uint8_t *out = CVPixelBufferGetBaseAddress(pixel);
    size_t stride = CVPixelBufferGetBytesPerRow(pixel);
    check(abs(out[4*4+4*stride] - 30) <= 4,"MJPEG top row orientation and luma");
    check(abs(out[4*4+24*stride] - 220) <= 4,"MJPEG bottom row orientation and luma");
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pixel);
    check(ALCopyUVCFrame(data.bytes,data.length,16,height,0,YES,NO) == NULL,"reject JPEG descriptor mismatch");
    CFRelease(encoder); CGImageRelease(source); CGContextRelease(bitmap); CGColorSpaceRelease(space);
}
int main(void) {
    @autoreleasepool {
        raw(NO); raw(YES); jpeg();
        uint8_t garbage[16]={0};
        check(ALCopyUVCFrame(garbage,sizeof(garbage),2,2,0,YES,NO) == NULL,"reject non-JPEG");
        check(ALCopyUVCFrame(garbage,sizeof(garbage),1920,1920,0,NO,NO) == NULL,"reject oversized image");
        check(ALCopyUVCFrame(NULL,16,2,2,0,NO,NO) == NULL,"reject null buffer");
        puts("PASS UVC YUY2/UYVY/MJPEG ownership, orientation, range, stride and malformed frames");
    }
    return 0;
}
