#import "ALStreamClient.h"
#import <CoreMedia/CoreMedia.h>
#import <os/log.h>
#import <AudioToolbox/AudioToolbox.h>

const uint32_t ALVideoType = 0x6D617266; // ASCII "fram" read as little-endian
const uint32_t ALAudioType = 0x69647561; // ASCII "audi" read as little-endian
const uint32_t ALAACType = 0x61636161; // ASCII "aaca" read as little-endian
const uint32_t ALAACConfigType = 0x64636161; // ASCII "aacd" read as little-endian
const NSUInteger ALVideoHeaderLength = 20;
const NSUInteger ALAudioHeaderLength = 12;

@interface ALStreamClient () {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    NSURLSession *_preferredSession;
    NSURLSessionWebSocketTask *_preferredTask;
    dispatch_source_t _preferredTimer;
    dispatch_source_t _healthTimer;
    CFAbsoluteTime _lastMessageTime;
    dispatch_queue_t _queue;
    BOOL _connected;
    BOOL _stopping;
    BOOL _reconnectScheduled;
    NSString *_address;
    NSArray<NSString *> *_addresses;
    NSUInteger _nextAddressIndex;
    NSUInteger _activeAddressIndex;
    NSUInteger _generation;
    AudioConverterRef _aacDecoder;
    uint32_t _aacRate;
    uint32_t _aacChannels;
    NSData *_aacConfig;
}
@property(atomic, readwrite, getter=isConnected) BOOL connected;
@property(atomic, copy, readwrite) NSString *address;
@end

static uint32_t ALReadLE32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0]) | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

typedef struct {
    const void *bytes;
    UInt32 size;
    UInt32 channels;
    BOOL supplied;
    AudioStreamPacketDescription description;
} ALAACInput;
static OSStatus ALAACProvide(AudioConverterRef converter, UInt32 *packets,
                              AudioBufferList *buffers, AudioStreamPacketDescription **descriptions,
                              void *context) {
    ALAACInput *input = context;
    if (input->supplied || !*packets) { *packets = 0; return 'alnd'; }
    input->supplied = YES;
    *packets = 1;
    buffers->mNumberBuffers = 1;
    buffers->mBuffers[0] = (AudioBuffer){input->channels, input->size, (void *)input->bytes};
    input->description = (AudioStreamPacketDescription){0, 1024, input->size};
    if (descriptions) *descriptions = &input->description;
    (void)converter;
    return noErr;
}

static char ALStreamQueueKey;

@implementation ALStreamClient

- (void)dealloc {
    if (_aacDecoder) AudioConverterDispose(_aacDecoder);
}

- (void)_resetAACLocked {
    // USB receive and WebSocket teardown run on different queues. Serialize
    // converter lifetime with decoding; never dispose a converter in use.
    @synchronized (self) {
        if (_aacDecoder) AudioConverterDispose(_aacDecoder);
        _aacDecoder = NULL; _aacConfig = nil; _aacRate = 0; _aacChannels = 0;
    }
}

- (void)_decodeAACLocked:(NSData *)data sampleRate:(uint32_t)rate channels:(uint32_t)channels {
    if (!_aacConfig || rate != _aacRate || channels != _aacChannels || data.length > 65536) return;
    if (!_aacDecoder) {
        AudioStreamBasicDescription input = {0}, output = {0};
        input.mFormatID = kAudioFormatMPEG4AAC;
        input.mFormatFlags = kMPEG4Object_AAC_LC;
        input.mSampleRate = rate; input.mChannelsPerFrame = channels;
        input.mFramesPerPacket = 1024;
        output.mFormatID = kAudioFormatLinearPCM;
        output.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        output.mSampleRate = rate; output.mChannelsPerFrame = channels;
        output.mBitsPerChannel = 32; output.mFramesPerPacket = 1;
        output.mBytesPerFrame = output.mBytesPerPacket = channels * sizeof(float);
        OSStatus status = AudioConverterNew(&input, &output, &_aacDecoder);
        if (status != noErr) {
            os_log_error(OS_LOG_DEFAULT, "[AppleLive] AAC converter creation failed: %d", (int)status);
            _aacDecoder = NULL; return;
        }
        // AAC-LC is fully described by the validated ASC's rate and channel
        // count above. Raw FFmpeg ASC bytes are not an AudioConverter ESDS
        // magic cookie; passing them as one causes parameter errors on macOS.
    }
    float pcm[2048];
    AudioBufferList output = {1, {{channels, sizeof(pcm), pcm}}};
    ALAACInput input = {data.bytes, (UInt32)data.length, channels, NO, {0}};
    UInt32 frames = 1024;
    OSStatus status = AudioConverterFillComplexBuffer(_aacDecoder, ALAACProvide, &input, &frames, &output, NULL);
    if ((status == noErr || status == 'alnd') && frames > 0 && frames <= 1024 && self.onAudioPCM)
        self.onAudioPCM(pcm, frames, channels, rate);
    else if (status != noErr && status != 'alnd') {
        static uint64_t errors = 0;
        uint64_t count = __sync_add_and_fetch(&errors, 1);
        if (count <= 3 || count % 300 == 0)
            os_log_error(OS_LOG_DEFAULT, "[AppleLive] AAC decode failed: %d", (int)status);
        AudioConverterReset(_aacDecoder);
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.applelive.stream", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &ALStreamQueueKey, (__bridge void *)self, NULL);
    }
    return self;
}

- (void)connectToAddress:(NSString *)address {
    [self connectToAddresses:address.length ? @[address] : @[]];
}

- (void)connectToAddresses:(NSArray<NSString *> *)addresses {
    NSMutableArray<NSString *> *validAddresses = [NSMutableArray array];
    for (id address in addresses) {
        if (![address isKindOfClass:[NSString class]] || ![address length]) continue;
        NSString *urlString = address;
        if (![urlString hasPrefix:@"ws://"] && ![urlString hasPrefix:@"wss://"]) {
            urlString = [NSString stringWithFormat:@"ws://%@", urlString];
        }
        NSURL *url = [NSURL URLWithString:urlString];
        if (url.host.length) [validAddresses addObject:urlString];
    }
    if (!validAddresses.count) return;
    dispatch_async(_queue, ^{
        self->_generation++;
        self->_stopping = NO;
        self->_reconnectScheduled = NO;
        [self _resetAACLocked];
        [self _stopPreferredProbeLocked];
        self->_addresses = [validAddresses copy];
        self->_nextAddressIndex = 0;
        if (self.onDisconnected) self.onDisconnected();
        self->_healthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_healthTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak typeof(self) healthSelf = self;
        dispatch_source_set_event_handler(self->_healthTimer, ^{ [healthSelf _checkHealthLocked]; });
        dispatch_resume(self->_healthTimer);
        if (self->_addresses.count > 1) {
            self->_preferredTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
            dispatch_source_set_timer(self->_preferredTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                      5 * NSEC_PER_SEC, NSEC_PER_SEC);
            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(self->_preferredTimer, ^{
                [weakSelf _probePreferredLocked];
            });
            dispatch_resume(self->_preferredTimer);
        }
        [self _connectNextLocked];
    });
}

- (void)_connectNextLocked {
    [self _cancelPreferredAttemptLocked];
    [self _disconnectLocked];
    _activeAddressIndex = _nextAddressIndex;
    NSString *urlString = _addresses[_nextAddressIndex];
    _nextAddressIndex = (_nextAddressIndex + 1) % _addresses.count;
    NSURL *url = [NSURL URLWithString:urlString];
    self.address = urlString;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 3.0;
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    self->_session = [NSURLSession sessionWithConfiguration:configuration
                                                   delegate:self
                                              delegateQueue:delegateQueue];
    self->_task = [self->_session webSocketTaskWithURL:url];
    [self->_task resume];
}

- (void)disconnect {
    dispatch_block_t teardown = ^{
        self->_stopping = YES;
        self->_generation++;
        self->_reconnectScheduled = NO;
        [self _stopPreferredProbeLocked];
        [self _disconnectLocked];
        if (self.onDisconnected) self.onDisconnected();
    };
    if (dispatch_get_specific(&ALStreamQueueKey) == (__bridge void *)self) teardown();
    else dispatch_sync(_queue, teardown);
}

- (void)_cancelPreferredAttemptLocked {
    if (_preferredTask) {
        [_preferredTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        _preferredTask = nil;
    }
    [_preferredSession invalidateAndCancel];
    _preferredSession = nil;
}

- (void)_stopPreferredProbeLocked {
    [self _cancelPreferredAttemptLocked];
    if (_preferredTimer) {
        dispatch_source_cancel(_preferredTimer);
        _preferredTimer = nil;
    }
    if (_healthTimer) {
        dispatch_source_cancel(_healthTimer);
        _healthTimer = nil;
    }
}

- (void)_checkHealthLocked {
    if (_stopping || !self.connected || CFAbsoluteTimeGetCurrent() - _lastMessageTime < 5) return;
    os_log(OS_LOG_DEFAULT, "[AppleLive] no stream data for 5 seconds; reconnecting");
    [self _disconnectLocked];
    [self _scheduleReconnect];
}

- (void)_probePreferredLocked {
    if (_stopping || !self.connected || _activeAddressIndex == 0 || _preferredTask) return;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 2.0;
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _preferredSession = [NSURLSession sessionWithConfiguration:configuration
                                                      delegate:self
                                                 delegateQueue:delegateQueue];
    _preferredTask = [_preferredSession webSocketTaskWithURL:[NSURL URLWithString:_addresses[0]]];
    [_preferredTask resume];
}

- (void)_disconnectLocked {
    if (_task) {
        [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        _task = nil;
    }
    [_session invalidateAndCancel];
    _session = nil;
    [self _resetAACLocked];
    self.connected = NO;
}

- (void)_receiveNext {
    NSURLSessionWebSocketTask *task = _task;
    if (!task) return;
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        dispatch_async(self->_queue, ^{
            if (task != self->_task) return;
            if (error) {
                self.connected = NO;
                if (!self->_stopping) [self _scheduleReconnect];
                return;
            }
            if (message.type == NSURLSessionWebSocketMessageTypeData) {
                self->_lastMessageTime = CFAbsoluteTimeGetCurrent();
                [self _handleBinary:message.data];
            } else if (message.string.length) {
                [self _handleText:message.string];
            }
            [self _receiveNext];
        });
    }];
}

- (void)_scheduleReconnect {
    if (_stopping || _reconnectScheduled) return;
    if (!_addresses.count) return;
    if (self.onDisconnected) self.onDisconnected();
    _reconnectScheduled = YES;
    NSUInteger generation = _generation;
    NSTimeInterval delay = _nextAddressIndex == 0 ? 2.0 : 0.2;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        if (generation != self->_generation) return;
        self->_reconnectScheduled = NO;
        if (!self->_stopping && !self.connected) {
            [self _connectNextLocked];
        }
    });
}

- (void)_handleText:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([json[@"type"] isEqualToString:@"ping"]) {
        NSData *pong = [NSJSONSerialization dataWithJSONObject:@{ @"type": @"pong" } options:0 error:nil];
        if (pong) {
            NSString *value = [[NSString alloc] initWithData:pong encoding:NSUTF8StringEncoding];
            [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:value]
             completionHandler:^(NSError *error) {
                if (error) {
                    os_log_error(OS_LOG_DEFAULT, "[AppleLive] pong send failed: %{public}@", error);
                }
            }];
        }
    }
}

- (void)_handleBinary:(NSData *)data {
    [self acceptBinaryData:data];
}
- (void)acceptBinaryData:(NSData *)data {
    @autoreleasepool {
        @synchronized (self) { [self _acceptBinaryLocked:data]; }
    }
}

- (void)_acceptBinaryLocked:(NSData *)data {
    if (data.length < 4 || data.length > 8 * 1024 * 1024) return;
    const uint8_t *bytes = data.bytes;
    uint32_t type = ALReadLE32(bytes);
    if (type == ALVideoType) {
        if (data.length < ALVideoHeaderLength) return;
        uint32_t sequence = ALReadLE32(bytes + 4);
        uint32_t flags = ALReadLE32(bytes + 8);
        uint32_t width = ALReadLE32(bytes + 12);
        uint32_t height = ALReadLE32(bytes + 16);
        if (!width || !height || width > 8192 || height > 8192 || data.length > 8 * 1024 * 1024) return;
        NSData *nal = [data subdataWithRange:NSMakeRange(ALVideoHeaderLength,
                                                         data.length - ALVideoHeaderLength)];
        if (self.onVideoNAL) self.onVideoNAL(nal, sequence, flags, width, height);
    } else if (type == ALAudioType) {
        if (data.length < ALAudioHeaderLength) return;
        uint32_t rate = ALReadLE32(bytes + 4);
        uint32_t channels = ALReadLE32(bytes + 8);
        if ((channels != 1 && channels != 2) || rate < 8000 || rate > 192000) return;
        NSUInteger payloadLength = data.length - ALAudioHeaderLength;
        payloadLength -= payloadLength % sizeof(float);
        if (payloadLength && channels && self.onAudioPCM) {
            const float *samples = (const float *)(bytes + ALAudioHeaderLength);
            NSUInteger floatCount = payloadLength / sizeof(float);
            self.onAudioPCM(samples, floatCount / channels, channels, rate);
        }
    } else if (type == ALAACConfigType) {
        [self _resetAACLocked];
        if (data.length < ALAudioHeaderLength + 2 || data.length > ALAudioHeaderLength + 64) return;
        uint32_t rate = ALReadLE32(bytes + 4), channels = ALReadLE32(bytes + 8);
        const uint8_t *asc = bytes + ALAudioHeaderLength;
        const uint32_t rates[] = {96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
        unsigned frequency = ((asc[0] & 7) << 1) | (asc[1] >> 7);
        unsigned configChannels = (asc[1] >> 3) & 15;
        // The native sender is AAC-LC, mono or stereo. Reject unsupported or
        // inconsistent headers before creating an AudioConverter.
        if ((asc[0] >> 3) != 2 || frequency >= 13 || rates[frequency] != rate ||
            configChannels != channels || (channels != 1 && channels != 2)) return;
        _aacRate = rate; _aacChannels = channels;
        _aacConfig = [data subdataWithRange:NSMakeRange(ALAudioHeaderLength, data.length - ALAudioHeaderLength)];
    } else if (type == ALAACType) {
        if (data.length < ALAudioHeaderLength + 1) return;
        uint32_t rate = ALReadLE32(bytes + 4);
        uint32_t channels = ALReadLE32(bytes + 8);
        if ((channels != 1 && channels != 2) || rate < 8000 || rate > 192000) return;
        NSData *aac = [data subdataWithRange:NSMakeRange(ALAudioHeaderLength, data.length - ALAudioHeaderLength)];
        [self _decodeAACLocked:aac sampleRate:rate channels:channels];
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol {
    dispatch_async(_queue, ^{
        if (webSocketTask == self->_preferredTask) {
            NSURLSession *oldSession = self->_session;
            NSURLSessionWebSocketTask *oldTask = self->_task;
            self->_session = self->_preferredSession;
            self->_task = self->_preferredTask;
            self->_preferredSession = nil;
            self->_preferredTask = nil;
            self->_activeAddressIndex = 0;
            self->_nextAddressIndex = 1;
            self.address = self->_addresses[0];
            if (self.onDisconnected) self.onDisconnected();
            [oldTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
            [oldSession invalidateAndCancel];
            self.connected = YES;
            self->_lastMessageTime = CFAbsoluteTimeGetCurrent();
            [self _receiveNext];
            return;
        }
        if (webSocketTask != self->_task) return;
        self.connected = YES;
        self->_lastMessageTime = CFAbsoluteTimeGetCurrent();
        [self _receiveNext];
    });
    (void)session;
    (void)webSocketTask;
    (void)protocol;
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    dispatch_async(_queue, ^{
        if (webSocketTask == self->_preferredTask) {
            [self _cancelPreferredAttemptLocked];
            return;
        }
        if (webSocketTask != self->_task) return;
        self.connected = NO;
        if (!self->_stopping) [self _scheduleReconnect];
    });
    (void)session;
    (void)webSocketTask;
    (void)closeCode;
    (void)reason;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        os_log_error(OS_LOG_DEFAULT, "[AppleLive] websocket error: %{public}@", error);
        dispatch_async(_queue, ^{
            if (task == self->_preferredTask) {
                [self _cancelPreferredAttemptLocked];
                return;
            }
            if (task != self->_task || self->_stopping) return;
            self.connected = NO;
            [self _scheduleReconnect];
        });
    }
    (void)session;
}

@end
