#import "ALVideoDecoder.h"
#import "ALColorPipeline.h"
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <os/log.h>
#include <stdint.h>

static void ALReportDecodeError(const char *stage, OSStatus status) {
    static uint64_t errors = 0;
    uint64_t count = __sync_add_and_fetch(&errors, 1);
    if (count <= 3 || count % 300 == 0) {
        os_log_error(OS_LOG_DEFAULT, "[AppleLive] decoder %{public}s failed status=%d errors=%llu",
                     stage, (int)status, count);
    }
}

@interface ALVideoDecoder () {
    NSData *_sps;
    NSData *_pps;
    CMVideoFormatDescriptionRef _formatDescription;
    VTDecompressionSessionRef _session;
    os_unfair_lock _lock;
    BOOL _needsKeyframe;
    BOOL _hasSequence;
    uint32_t _lastSequence;
}
@property(atomic) OSStatus callbackStatus;
@end

static void ALDecodeCallback(void *refCon, void *frameRefCon, OSStatus status,
                             VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                             CMTime pts, CMTime duration) {
    ALVideoDecoder *decoder = (__bridge ALVideoDecoder *)refCon;
    if (status == noErr && imageBuffer && decoder.onFrame) {
        ALSetDefaultVideoColorAttachments((CVPixelBufferRef)imageBuffer);
        decoder.onFrame((CVPixelBufferRef)imageBuffer, (uint32_t)(uintptr_t)frameRefCon);
        static uint64_t frames = 0;
        uint64_t count = __sync_add_and_fetch(&frames, 1);
        if (count == 1 || count % 300 == 0) {
            os_log(OS_LOG_DEFAULT, "[AppleLive] decoded frames=%llu size=%dx%d", count,
                   (int)CVPixelBufferGetWidth(imageBuffer), (int)CVPixelBufferGetHeight(imageBuffer));
        }
    } else if (status != noErr) {
        decoder.callbackStatus = status;
        ALReportDecodeError("callback", status);
    }
    (void)infoFlags;
    (void)pts;
    (void)duration;
}

@implementation ALVideoDecoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _needsKeyframe = YES;
    }
    return self;
}

- (void)dealloc {
    [self reset];
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    if (_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    _hasSequence = NO;
    _sps = nil;
    _pps = nil;
    _needsKeyframe = YES;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)createSessionIfNeeded {
    if (_session || !_sps || !_pps) return _session != NULL;
    const uint8_t *parameterSets[2] = {_sps.bytes, _pps.bytes};
    size_t parameterSizes[2] = {_sps.length, _pps.length};
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, parameterSets, parameterSizes, 4, &format);
    if (status != noErr || !format) {
        ALReportDecodeError("format", status);
        return NO;
    }

    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    if (dimensions.width <= 0 || dimensions.height <= 0 || dimensions.width > 8192 ||
        dimensions.height > 8192 || (uint64_t)dimensions.width * dimensions.height > 16777216) {
        CFRelease(format); return NO;
    }
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = ALDecodeCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };
    VTDecompressionSessionRef session = NULL;
    status = VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL,
                                           (__bridge CFDictionaryRef)attributes,
                                           &callback, &session);
    if (status != noErr || !session) {
        ALReportDecodeError("session", status);
        CFRelease(format);
        return NO;
    }
    _formatDescription = format;
    _session = session;
    VTSessionSetProperty(session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return YES;
}

- (void)decodeNAL:(NSData *)nalData sequence:(uint32_t)sequence {
    [self decodeAccessUnit:nalData sequence:sequence flags:0];
}

- (void)decodeAccessUnit:(NSData *)data sequence:(uint32_t)sequence flags:(uint32_t)flags {
    os_unfair_lock_lock(&_lock);
    // Bit 1 denotes complete access units, with one sequence number per frame.
    // Legacy per-NAL senders do not provide this guarantee.
    if (flags & 2) {
        if (_hasSequence && sequence != (uint32_t)(_lastSequence + 1)) [self resetSessionLocked];
        _hasSequence = YES; _lastSequence = sequence;
    } else _hasSequence = NO;
    [self decodeLocked:data sequence:sequence];
    os_unfair_lock_unlock(&_lock);
}

- (void)decodeLocked:(NSData *)nalData sequence:(uint32_t)sequence {
    if (!nalData.length || nalData.length > 8 * 1024 * 1024) return;
    const uint8_t *bytes = nalData.bytes;
    const size_t length = nalData.length;
    NSMutableArray<NSData *> *slices = [NSMutableArray array];
    BOOL hasKeyframe = NO;

    // A frame can contain more than one slice NAL.  The old implementation
    // treated the whole packet as one NAL and fed a trailing start code to
    // VideoToolbox, which produces corrupted pictures on some iOS versions.
    // Split every Annex-B NAL first, then submit all slices in one sample.
    size_t cursor = 0;
    while (cursor + 3 <= length) {
        size_t start = SIZE_MAX, startCode = 0;
        for (size_t index = cursor; index + 3 <= length; index++) {
            if (index + 4 <= length && bytes[index] == 0 && bytes[index + 1] == 0 &&
                bytes[index + 2] == 0 && bytes[index + 3] == 1) {
                start = index; startCode = 4; break;
            }
            if (bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1) {
                start = index; startCode = 3; break;
            }
        }
        if (start == SIZE_MAX || start + startCode >= length) break;
        size_t next = length;
        for (size_t index = start + startCode; index + 3 <= length; index++) {
            if ((index + 4 <= length && bytes[index] == 0 && bytes[index + 1] == 0 &&
                 bytes[index + 2] == 0 && bytes[index + 3] == 1) ||
                (bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1)) {
                next = index;
                break;
            }
        }
        size_t payloadLength = next - (start + startCode);
        if (payloadLength) {
            const uint8_t *payload = bytes + start + startCode;
            uint8_t nalType = payload[0] & 0x1F;
            if (nalType == 7 || nalType == 8) {
                // Parameter sets are copied while the input NSData remains
                // owned by the USB/WebSocket receive callback.
                NSData *parameterSet = [NSData dataWithBytes:payload length:payloadLength];
                if (nalType == 7 && ![_sps isEqualToData:parameterSet]) {
                    _sps = parameterSet;
                    [self resetSessionLocked];
                } else if (nalType == 8 && ![_pps isEqualToData:parameterSet]) {
                    _pps = parameterSet;
                    [self resetSessionLocked];
                }
            } else if (nalType == 1 || nalType == 5) {
                [slices addObject:[NSData dataWithBytes:payload length:payloadLength]];
                hasKeyframe = hasKeyframe || nalType == 5;
            }
        }
        cursor = next;
        if (cursor == length) break;
    }
    if (!slices.count) return;

    // Never decode a delta frame after a reconnect or parameter-set change.
    // Waiting for the next IDR prevents the decoder from displaying blocks
    // and avoids cascading VideoToolbox failures after a dropped USB packet.
    if (_needsKeyframe && !hasKeyframe) {
        return;
    }
    if (![self createSessionIfNeeded]) {
        return;
    }

    size_t blockLength = 0;
    for (NSData *slice in slices) blockLength += slice.length + 4;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, blockLength, kCFAllocatorDefault, NULL,
        0, blockLength, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status == kCMBlockBufferNoErr) {
        size_t offset = 0;
        for (NSData *slice in slices) {
            uint32_t sliceLength = CFSwapInt32HostToBig((uint32_t)slice.length);
            status = CMBlockBufferReplaceDataBytes(&sliceLength, block, offset, 4);
            if (status != kCMBlockBufferNoErr) break;
            status = CMBlockBufferReplaceDataBytes(slice.bytes, block, offset + 4,
                                                    slice.length);
            if (status != kCMBlockBufferNoErr) break;
            offset += slice.length + 4;
        }
    }
    if (status != kCMBlockBufferNoErr) {
        if (block) CFRelease(block);
        return;
    }

    const size_t sampleSize = blockLength;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(sequence, 30),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _formatDescription,
                                       1, 1, &timing, 1, &sampleSize, &sample);
    CFRelease(block);
    if (status == noErr && sample) {
        self.callbackStatus = noErr;
        VTDecodeInfoFlags info = 0;
        OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_session, sample,
                                           0,
                                           (void *)(uintptr_t)sequence, &info);
        if (decodeStatus != noErr || self.callbackStatus != noErr) {
            ALReportDecodeError("frame", decodeStatus != noErr ? decodeStatus : self.callbackStatus);
            [self resetSessionLocked];
        } else if (hasKeyframe) {
            _needsKeyframe = NO;
        }
        CFRelease(sample);
    }
}

- (void)resetSessionLocked {
    if (_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    _needsKeyframe = YES;
}

@end
