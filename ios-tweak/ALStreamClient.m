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
    dispatch_queue_t _queue;
    BOOL _connected;
    BOOL _stopping;
    NSString *_address;
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
    if (!address.length) return;
    dispatch_async(_queue, ^{
        self->_stopping = NO;
        [self _disconnectLocked];
        NSString *urlString = address;
        if (![urlString hasPrefix:@"ws://"] && ![urlString hasPrefix:@"wss://"]) {
            urlString = [NSString stringWithFormat:@"ws://%@", urlString];
        }
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url || !url.host) {
            os_log_error(OS_LOG_DEFAULT, "[AppleLive] invalid server address: %{public}@", address);
            return;
        }
        self.address = urlString;
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10.0;
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        self->_session = [NSURLSession sessionWithConfiguration:configuration
                                                       delegate:self
                                                  delegateQueue:delegateQueue];
        self->_task = [self->_session webSocketTaskWithURL:url];
        [self->_task resume];
    });
}

- (void)disconnect {
    dispatch_async(_queue, ^{
        self->_stopping = YES;
        [self _disconnectLocked];
    });
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
    NSString *address = self.address;
    if (!address.length) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _queue, ^{
        if (!self->_stopping && !self.connected) [self connectToAddress:address];
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
             completionHandler:nil];
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
        self.connected = NO;
        if (!self->_stopping) [self _scheduleReconnect];
    });
    (void)session;
    (void)webSocketTask;
    (void)closeCode;
    (void)reason;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) os_log_error(OS_LOG_DEFAULT, "[AppleLive] websocket error: %{public}@", error);
    (void)session;
    (void)task;
}

@end
