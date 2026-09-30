#import "ALFrameStore.h"
#import <os/lock.h>

@implementation ALFrameStore {
    CVPixelBufferRef _pixelBuffer;
    uint32_t _sequence;
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    [self clear];
}

- (void)storePixelBuffer:(CVPixelBufferRef)pixelBuffer sequence:(uint32_t)sequence {
    if (!pixelBuffer) return;
    CVPixelBufferRetain(pixelBuffer);
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _pixelBuffer;
    _pixelBuffer = pixelBuffer;
    _sequence = sequence;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

- (CVPixelBufferRef)copyLatestPixelBuffer {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef result = _pixelBuffer;
    if (result) CVPixelBufferRetain(result);
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (uint32_t)latestSequence {
    os_unfair_lock_lock(&_lock);
    uint32_t value = _sequence;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)clear {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _pixelBuffer;
    _pixelBuffer = NULL;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

@end
