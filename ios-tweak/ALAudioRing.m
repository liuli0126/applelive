#import "ALAudioRing.h"
#import <os/lock.h>
#import <string.h>

static const NSUInteger kALRingFrameCapacity = 48000 / 5; // 200 ms at 48 kHz

@implementation ALAudioRing {
    float *_buffer;
    NSUInteger _readFrame;
    NSUInteger _writeFrame;
    NSUInteger _availableFrames;
    double _sourceRate;
    double _fraction;
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = calloc(kALRingFrameCapacity * 2, sizeof(float));
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    free(_buffer);
}

- (void)clear {
    os_unfair_lock_lock(&_lock);
    _readFrame = _writeFrame = _availableFrames = 0;
    _sourceRate = _fraction = 0;
    os_unfair_lock_unlock(&_lock);
}

- (void)pushSamples:(const float *)samples count:(NSUInteger)count
           channels:(NSUInteger)channels sampleRate:(double)sampleRate {
    if (!samples || count == 0 || (channels != 1 && channels != 2) || sampleRate <= 0) return;
    if (count > kALRingFrameCapacity) {
        samples += (count - kALRingFrameCapacity) * channels;
        count = kALRingFrameCapacity;
    }
    os_unfair_lock_lock(&_lock);
    if (_sourceRate != sampleRate) {
        _readFrame = _writeFrame = _availableFrames = 0;
        _fraction = 0;
        _sourceRate = sampleRate;
    }
    NSUInteger overflow = (_availableFrames + count > kALRingFrameCapacity)
        ? (_availableFrames + count - kALRingFrameCapacity) : 0;
    _readFrame = (_readFrame + overflow) % kALRingFrameCapacity;
    _availableFrames -= overflow;
    if (overflow) _fraction = 0;
    for (NSUInteger i = 0; i < count; i++) {
        float left = samples[i * channels];
        float right = channels == 2 ? samples[i * channels + 1] : left;
        _buffer[_writeFrame * 2] = left;
        _buffer[_writeFrame * 2 + 1] = right;
        _writeFrame = (_writeFrame + 1) % kALRingFrameCapacity;
    }
    _availableFrames += count;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)popSamples:(float *)output count:(NSUInteger)count
          channels:(NSUInteger)channels sampleRate:(double)sampleRate {
    if (!output || count == 0 || channels == 0 || sampleRate <= 0) return NO;
    os_unfair_lock_lock(&_lock);
    NSUInteger produced = 0;
    double step = _sourceRate / sampleRate;
    while (produced < count && _availableFrames && step > 0) {
        NSUInteger nextFrame = _availableFrames > 1
            ? (_readFrame + 1) % kALRingFrameCapacity : _readFrame;
        float left = (float)(_buffer[_readFrame * 2] * (1.0 - _fraction)
                             + _buffer[nextFrame * 2] * _fraction);
        float right = (float)(_buffer[_readFrame * 2 + 1] * (1.0 - _fraction)
                              + _buffer[nextFrame * 2 + 1] * _fraction);
        if (channels == 1) {
            output[produced] = (left + right) * 0.5f;
        } else {
            output[produced * channels] = left;
            output[produced * channels + 1] = right;
            for (NSUInteger channel = 2; channel < channels; channel++) {
                output[produced * channels + channel] = 0;
            }
        }
        produced++;
        _fraction += step;
        NSUInteger advance = MIN((NSUInteger)_fraction, _availableFrames);
        _readFrame = (_readFrame + advance) % kALRingFrameCapacity;
        _availableFrames -= advance;
        _fraction -= advance;
        if (!_availableFrames) _fraction = 0;
    }
    if (produced < count) {
        memset(output + produced * channels, 0, (count - produced) * channels * sizeof(float));
    }
    os_unfair_lock_unlock(&_lock);
    return produced > 0;
}

@end
