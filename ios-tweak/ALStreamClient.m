#import "ALStreamClient.h"
#import <CoreMedia/CoreMedia.h>
#import <os/log.h>

const uint32_t ALVideoType = 0x6D617266; // ASCII "fram" read as little-endian
const uint32_t ALAudioType = 0x69647561; // ASCII "audi" read as little-endian
const NSUInteger ALVideoHeaderLength = 20;
const NSUInteger ALAudioHeaderLength = 12;

@interface ALStreamClient () {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    NSURLSession *_preferredSession;
    NSURLSessionWebSocketTask *_preferredTask;
    dispatch_source_t _preferredTimer;
    dispatch_queue_t _queue;
    BOOL _connected;
    BOOL _stopping;
    BOOL _reconnectScheduled;
    NSString *_address;
    NSArray<NSString *> *_addresses;
    NSUInteger _nextAddressIndex;
    NSUInteger _activeAddressIndex;
}
@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic, copy, readwrite) NSString *address;
@end

static uint32_t ALReadLE32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0]) | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

@implementation ALStreamClient

- (instancetype)init {
    self = [super init];
    if (self) _queue = dispatch_queue_create("com.applelive.stream", DISPATCH_QUEUE_SERIAL);
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
        self->_stopping = NO;
        self->_reconnectScheduled = NO;
        [self _stopPreferredProbeLocked];
        self->_addresses = [validAddresses copy];
        self->_nextAddressIndex = 0;
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
    dispatch_async(_queue, ^{
        self->_stopping = YES;
        self->_reconnectScheduled = NO;
        [self _stopPreferredProbeLocked];
        [self _disconnectLocked];
    });
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
    NSTimeInterval delay = _nextAddressIndex == 0 ? 2.0 : 0.2;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
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
    if (data.length < 4) return;
    const uint8_t *bytes = data.bytes;
    uint32_t type = ALReadLE32(bytes);
    if (type == ALVideoType) {
        if (data.length < ALVideoHeaderLength) return;
        uint32_t sequence = ALReadLE32(bytes + 4);
        uint32_t flags = ALReadLE32(bytes + 8);
        uint32_t width = ALReadLE32(bytes + 12);
        uint32_t height = ALReadLE32(bytes + 16);
        NSData *nal = [data subdataWithRange:NSMakeRange(ALVideoHeaderLength,
                                                         data.length - ALVideoHeaderLength)];
        if (self.onVideoNAL) self.onVideoNAL(nal, sequence, flags, width, height);
    } else if (type == ALAudioType) {
        if (data.length < ALAudioHeaderLength) return;
        uint32_t rate = ALReadLE32(bytes + 4);
        uint32_t channels = ALReadLE32(bytes + 8);
        NSUInteger payloadLength = data.length - ALAudioHeaderLength;
        payloadLength -= payloadLength % sizeof(float);
        if (payloadLength && channels && self.onAudioPCM) {
            const float *samples = (const float *)(bytes + ALAudioHeaderLength);
            NSUInteger floatCount = payloadLength / sizeof(float);
            self.onAudioPCM(samples, floatCount / channels, channels, rate);
        }
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
            [self _receiveNext];
            return;
        }
        if (webSocketTask != self->_task) return;
        self.connected = YES;
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
