#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <stddef.h>
#include <stdint.h>

// Copy an untrusted USB frame into an owned, color-tagged BGRA buffer.
// Input remains owned by libuvc and must never escape its callback.
CVPixelBufferRef ALCopyUVCFrame(const void *bytes, size_t length, size_t width,
                              size_t height, size_t stride, BOOL jpeg, BOOL uyvy)
    CF_RETURNS_RETAINED;
