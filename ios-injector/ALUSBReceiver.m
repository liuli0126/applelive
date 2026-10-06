#import "ALUSBReceiver.h"
#import <Network/Network.h>

@interface ALUSBReceiver () {
    dispatch_queue_t _queue;
    nw_listener_t _listener;
    nw_connection_t _connection;
    NSUInteger _generation;
    dispatch_source_t _healthTimer;
    CFAbsoluteTime _lastPacketTime;
}
@end
static char ALUSBQueueKey;
@implementation ALUSBReceiver
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.applelive.usb", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &ALUSBQueueKey, (__bridge void *)self, NULL);
    }
    return self;
}
- (void)cancelConnection {
    if (_healthTimer) { dispatch_source_cancel(_healthTimer); _healthTimer = nil; }
    if (!_connection) return;
    nw_connection_set_state_changed_handler(_connection, nil);
    nw_connection_cancel(_connection); _connection = nil;
    if (self.onDisconnected) self.onDisconnected();
}
- (void)start {
    dispatch_async(_queue, ^{
        if (self->_listener) return;
        self->_generation++;
        nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host("127.0.0.1", "8766"));
        self->_listener = nw_listener_create(parameters);
        if (!self->_listener) return;
        NSUInteger generation = self->_generation;
        __weak typeof(self) weakSelf = self;
        nw_listener_set_queue(self->_listener, self->_queue);
        nw_listener_set_new_connection_handler(self->_listener, ^(nw_connection_t connection) {
            ALUSBReceiver *owner = weakSelf;
            if (!owner || generation != owner->_generation) { nw_connection_cancel(connection); return; }
            [owner cancelConnection]; owner->_connection = connection;
            nw_connection_set_queue(connection, owner->_queue);
            nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
                ALUSBReceiver *strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_connection != connection) return;
                if (state == nw_connection_state_ready) {
                    strongSelf->_lastPacketTime = CFAbsoluteTimeGetCurrent();
                    strongSelf->_healthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, strongSelf->_queue);
                    dispatch_source_set_timer(strongSelf->_healthTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
                    dispatch_source_set_event_handler(strongSelf->_healthTimer, ^{
                        ALUSBReceiver *receiver = weakSelf;
                        if (receiver && receiver->_connection == connection && CFAbsoluteTimeGetCurrent() - receiver->_lastPacketTime > 5)
                            [receiver cancelConnection];
                    });
                    dispatch_resume(strongSelf->_healthTimer);
                    if (strongSelf.onConnected) strongSelf.onConnected();
                    NSData *magic = [@"ALUSB1\r\n" dataUsingEncoding:NSASCIIStringEncoding];
                    dispatch_data_t data = dispatch_data_create(magic.bytes, magic.length, strongSelf->_queue, ^{ (void)magic; });
                    nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t sendError) {
                        ALUSBReceiver *receiver = weakSelf;
                        if (!receiver || receiver->_connection != connection) return;
                        if (sendError) [receiver cancelConnection]; else [receiver receiveHeader:connection];
                    });
                } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) [strongSelf cancelConnection];
            });
            nw_connection_start(connection);
        });
        nw_listener_set_state_changed_handler(self->_listener, ^(nw_listener_state_t state, nw_error_t error) {
            ALUSBReceiver *owner = weakSelf;
            if (owner && generation == owner->_generation && state == nw_listener_state_failed) {
                nw_listener_cancel(owner->_listener); owner->_listener = nil;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), owner->_queue, ^{
                    if (generation == owner->_generation) [owner start];
                });
            }
        });
        nw_listener_start(self->_listener);
    });
}
- (void)stop {
    dispatch_block_t teardown = ^{
        self->_generation++;
        if (self->_listener) { nw_listener_cancel(self->_listener); self->_listener = nil; }
        [self cancelConnection];
    };
    if (dispatch_get_specific(&ALUSBQueueKey) == (__bridge void *)self) teardown();
    else dispatch_sync(_queue, teardown);
}
- (void)receiveHeader:(nw_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 4, 4, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        ALUSBReceiver *owner = weakSelf;
        if (!owner || connection != owner->_connection) return;
        const void *bytes = NULL; size_t size = 0;
        __attribute__((objc_precise_lifetime)) dispatch_data_t map = content ? dispatch_data_create_map(content, &bytes, &size) : nil;
        if (error || size != 4) { [owner cancelConnection]; return; }
        const uint8_t *header = bytes;
        uint32_t length = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
        (void)map;
        if (length < 4 || length > 8 * 1024 * 1024) { [owner cancelConnection]; return; }
        [owner receivePayload:connection length:length];
    });
}
- (void)receivePayload:(nw_connection_t)connection length:(uint32_t)length {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, length, length, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        ALUSBReceiver *owner = weakSelf;
        if (!owner || connection != owner->_connection) return;
        const void *bytes = NULL; size_t size = 0;
        __attribute__((objc_precise_lifetime)) dispatch_data_t map = content ? dispatch_data_create_map(content, &bytes, &size) : nil;
        if (error || size != length) { [owner cancelConnection]; return; }
        NSData *packet = [NSData dataWithBytes:bytes length:size]; (void)map;
        owner->_lastPacketTime = CFAbsoluteTimeGetCurrent();
        if (owner.onBinary) owner.onBinary(packet);
        [owner receiveHeader:connection];
    });
}
@end
