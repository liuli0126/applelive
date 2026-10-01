#import "ALVideoDecoder.h"
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <os/log.h>

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
}
@end

static size_t ALStartCodeLength(const uint8_t *bytes, size_t length) {
    if (length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1) return 4;
    if (length >= 3 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1) return 3;
    return 0;
}

static void ALDecodeCallback(void *refCon, void *frameRefCon, OSStatus status,
                             VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                             CMTime pts, CMTime duration) {
    ALVideoDecoder *decoder = (__bridge ALVideoDecoder *)refCon;
    if (status == noErr && imageBuffer && decoder.onFrame) {
        decoder.onFrame((CVPixelBufferRef)imageBuffer, (uint32_t)(uintptr_t)frameRefCon);
        static uint64_t frames = 0;
        uint64_t count = __sync_add_and_fetch(&frames, 1);
        if (count == 1 || count % 300 == 0) {
            os_log(OS_LOG_DEFAULT, "[AppleLive] decoded frames=%llu size=%dx%d", count,
                   (int)CVPixelBufferGetWidth(imageBuffer), (int)CVPixelBufferGetHeight(imageBuffer));
        }
    } else if (status != noErr) {
        ALReportDecodeError("callback", status);
    }
    (void)infoFlags;
    (void)pts;
    (void)duration;
}

@implementation ALVideoDecoder

- (instancetype)init {
    self = [super init];
    if (self) _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)dealloc {
    [self reset];
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    _sps = nil;
    _pps = nil;
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
    return YES;
}

- (void)decodeNAL:(NSData *)nalData sequence:(uint32_t)sequence {
    if (!nalData.length) return;
    const uint8_t *bytes = nalData.bytes;
    size_t startCode = ALStartCodeLength(bytes, nalData.length);
    if (!startCode || nalData.length <= startCode) return;
    const uint8_t *payload = bytes + startCode;
    size_t payloadLength = nalData.length - startCode;
    uint8_t nalType = payload[0] & 0x1F;

    os_unfair_lock_lock(&_lock);
    if (nalType == 7) {
        NSData *sps = [NSData dataWithBytes:payload length:payloadLength];
        if (![_sps isEqualToData:sps]) {
            _sps = sps;
            [self resetSessionLocked];
        }
        os_unfair_lock_unlock(&_lock);
        return;
    }
    if (nalType == 8) {
        NSData *pps = [NSData dataWithBytes:payload length:payloadLength];
        if (![_pps isEqualToData:pps]) {
            _pps = pps;
            [self resetSessionLocked];
        }
        os_unfair_lock_unlock(&_lock);
        return;
    }
    if (![self createSessionIfNeeded]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    size_t blockLength = payloadLength + 4;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, blockLength, kCFAllocatorDefault, NULL,
        0, blockLength, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status == kCMBlockBufferNoErr) {
        uint32_t length = CFSwapInt32HostToBig((uint32_t)payloadLength);
        status = CMBlockBufferReplaceDataBytes(&length, block, 0, 4);
        if (status == kCMBlockBufferNoErr) {
            status = CMBlockBufferReplaceDataBytes(payload, block, 4, payloadLength);
        }
    }
    if (status != kCMBlockBufferNoErr) {
        if (block) CFRelease(block);
        os_unfair_lock_unlock(&_lock);
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
        VTDecodeInfoFlags info = 0;
        OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_session, sample,
                                           kVTDecodeFrame_EnableAsynchronousDecompression,
                                           (void *)(uintptr_t)sequence, &info);
        if (decodeStatus != noErr) ALReportDecodeError("frame", decodeStatus);
        CFRelease(sample);
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)resetSessionLocked {
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
}

@end
