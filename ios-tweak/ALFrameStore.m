#import "ALFrameStore.h"
#import <os/lock.h>
#import <os/log.h>

@implementation ALFrameStore {
    CVPixelBufferRef _pixelBuffer;
    uint32_t _sequence;
    NSTimeInterval _receivedAt;
    BOOL _receiving;
    uint64_t _generation;
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
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval gap = _receiving ? now - _receivedAt : 0;
    _pixelBuffer = pixelBuffer;
    _sequence = sequence;
    _receivedAt = now;
    _receiving = YES;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
    if (gap >= 0.75) os_log(OS_LOG_DEFAULT, "[AppleLive] held video through %.3f second gap, resumed sequence=%u", gap, sequence);
}

- (CVPixelBufferRef)copyLatestPixelBuffer {
    os_unfair_lock_lock(&_lock);
    // A delayed packet or decoder reset must not switch the capture delegate
    // back to the physical camera. Keep one retained image until a new frame
    // arrives or the user explicitly clears/changes the selected source.
    CVPixelBufferRef result = _pixelBuffer;
    if (result) CVPixelBufferRetain(result);
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (BOOL)hasFrameReceivedWithin:(NSTimeInterval)interval {
    os_unfair_lock_lock(&_lock);
    NSTimeInterval age = NSProcessInfo.processInfo.systemUptime - _receivedAt;
    BOOL recent = _pixelBuffer && _receiving && age >= 0 && age < interval;
    os_unfair_lock_unlock(&_lock);
    return recent;
}

- (void)markInterrupted {
    os_unfair_lock_lock(&_lock);
    BOOL held = _receiving && _pixelBuffer != NULL;
    _receiving = NO;
    _receivedAt = 0;
    os_unfair_lock_unlock(&_lock);
    if (held) os_log(OS_LOG_DEFAULT, "[AppleLive] retaining last video frame during transport recovery");
}

- (uint64_t)generation {
    os_unfair_lock_lock(&_lock);
    uint64_t value = _generation;
    os_unfair_lock_unlock(&_lock);
    return value;
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
    _receivedAt = 0;
    _receiving = NO;
    _sequence = 0;
    _generation++;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

@end
