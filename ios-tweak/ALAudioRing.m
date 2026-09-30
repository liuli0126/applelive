#import "ALAudioRing.h"
#import <os/lock.h>
#import <string.h>

static const NSUInteger kALRingCapacity = 48000 * 2 * 2;

@implementation ALAudioRing {
    float *_buffer;
    NSUInteger _read;
    NSUInteger _write;
    NSUInteger _available;
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = calloc(kALRingCapacity, sizeof(float));
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    free(_buffer);
}

- (void)clear {
    os_unfair_lock_lock(&_lock);
    _read = _write = _available = 0;
    os_unfair_lock_unlock(&_lock);
}

- (void)pushSamples:(const float *)samples count:(NSUInteger)count
           channels:(NSUInteger)channels sampleRate:(double)sampleRate {
    if (!samples || count == 0 || channels == 0) return;
    NSUInteger total = count * channels;
    if (total > kALRingCapacity) {
        samples += total - kALRingCapacity;
        total = kALRingCapacity;
    }
    os_unfair_lock_lock(&_lock);
    NSUInteger overflow = (_available + total > kALRingCapacity)
        ? (_available + total - kALRingCapacity) : 0;
    _read = (_read + overflow) % kALRingCapacity;
    _available -= overflow;
    for (NSUInteger i = 0; i < total; i++) {
        _buffer[_write] = samples[i];
        _write = (_write + 1) % kALRingCapacity;
    }
    _available += total;
    os_unfair_lock_unlock(&_lock);
    (void)sampleRate;
}

- (BOOL)popSamples:(float *)output count:(NSUInteger)count
          channels:(NSUInteger)channels sampleRate:(double)sampleRate {
    if (!output || count == 0 || channels == 0) return NO;
    NSUInteger total = count * channels;
    os_unfair_lock_lock(&_lock);
    NSUInteger copyCount = MIN(total, _available);
    for (NSUInteger i = 0; i < copyCount; i++) {
        output[i] = _buffer[_read];
        _read = (_read + 1) % kALRingCapacity;
    }
    if (copyCount < total) memset(output + copyCount, 0, (total - copyCount) * sizeof(float));
    _available -= copyCount;
    BOOL hadData = copyCount > 0;
    os_unfair_lock_unlock(&_lock);
    (void)sampleRate;
    return hadData;
}

@end
