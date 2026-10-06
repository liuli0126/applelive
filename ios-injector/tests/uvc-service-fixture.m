#import "ALExternalCamera.h"
#import "ALUVCWire.h"
@interface ALExternalCamera () {
    dispatch_source_t _timer;
}
@property(atomic,copy,readwrite) NSDictionary *status;
@end
@implementation ALExternalCamera
- (instancetype)init { if ((self=[super init])) self.status=@{@"state":@"opening",@"message":@"fixture"};return self; }
- (void)start {
    self.status=@{@"state":@"playing",@"message":@"fixture streaming"};
    uint8_t pixels[]={16,128,235,128,16,128,235,128,16,128,235,128,16,128,235,128};
    NSData *frame=ALUVCPackFrame(pixels,sizeof(pixels),4,2,8,ALUVCYUY2);
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
    __weak typeof(self) weak=self;
    dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),20*NSEC_PER_MSEC,NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ ALExternalCamera *owner=weak;void (^handler)(NSData *)=owner.onRawFrame;if(handler) handler(frame); });
    dispatch_resume(_timer);
}
- (void)stop { if (_timer) { dispatch_source_cancel(_timer);_timer=nil; }self.onRawFrame=nil; }
- (void)stopAndWait { [self stop]; }
- (NSString *)diagnosticReport { return @"SIMULATED camera: no physical USB compatibility claim"; }
@end
