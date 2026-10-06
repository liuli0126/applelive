#import "ALUVCServiceClient.h"
#import "ALUVCWire.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>

static NSString *const tokenKey=@"AppleLive.UVCServiceToken.v1";
@interface ALUVCServiceClient () {
    dispatch_queue_t _queue;
    atomic_uint_fast64_t _generation;
    int _socket;
    uint16_t _port;
}
@property(atomic,copy,readwrite) NSDictionary *status;
@property(atomic,copy) NSString *serviceReport;
@end

@implementation ALUVCServiceClient
- (instancetype)init { return [self initWithPort:8767]; }
- (instancetype)initWithPort:(uint16_t)port {
    if ((self=[super init])) {
        _queue=dispatch_queue_create("com.applelive.uvc-service-client",DISPATCH_QUEUE_SERIAL);
        atomic_init(&_generation,0);_socket=-1;_port=port;
        self.status=@{@"state":@"stopped",@"message":@"外接相机未连接"};
    }
    return self;
}
+ (BOOL)saveConnectionCode:(NSString *)code {
    if (![code isKindOfClass:NSString.class]) return NO;
    NSString *token=[[code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!ALUVCValidToken(token)) return NO;
    [NSUserDefaults.standardUserDefaults setObject:token forKey:tokenKey];return YES;
}
- (void)message:(NSString *)message state:(NSString *)state code:(int)code generation:(uint64_t)generation {
    if (atomic_load(&_generation)!=generation) return;
    self.status=@{@"state":state,@"message":message,@"error":message,@"code":@(code),@"device":@"手机 UVC 采集服务"};
}
- (NSString *)diagnosticReport {
    return [NSString stringWithFormat:@"AppleLive UVC 服务连接 · %@ · %@\n%@\n%@",
        NSBundle.mainBundle.bundleIdentifier ?: @"test",NSProcessInfo.processInfo.operatingSystemVersionString,
        self.status[@"message"] ?: @"",self.serviceReport ?: @"尚未收到服务诊断"];
}
- (void)stop {
    atomic_fetch_add(&_generation,1);
    @synchronized (self) { if (_socket>=0) shutdown(_socket,SHUT_RDWR); }
}
- (void)start {
    [self stop];
    uint64_t generation=atomic_load(&_generation);
    self.serviceReport=nil;
    NSString *token=[NSUserDefaults.standardUserDefaults stringForKey:tokenKey];
    if (!ALUVCValidToken(token)) {
        // An unsandboxed jailbreak target can pair without clipboard setup.
        NSString *local=[NSString stringWithContentsOfFile:@"/var/mobile/Library/AppleLiveUVC/connection-token" encoding:NSUTF8StringEncoding error:nil];
        if ([ALUVCServiceClient saveConnectionCode:local]) token=[NSUserDefaults.standardUserDefaults stringForKey:tokenKey];
    }
    if (!ALUVCValidToken(token)) {
        [self message:@"请先安装并打开 AppleLive USB，复制连接码后在外接相机菜单中配对"
            state:@"error" code:401 generation:generation];return;
    }
    [self message:@"正在连接手机采集服务…" state:@"opening" code:0 generation:generation];
    dispatch_async(_queue, ^{ [self runWithToken:token generation:generation]; });
}
- (void)runWithToken:(NSString *)token generation:(uint64_t)generation {
    if (atomic_load(&_generation)!=generation) return;
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0) { [self message:@"无法创建本机连接" state:@"error" code:errno generation:generation];return; }
    ALUVCConfigureSocket(fd);
    @synchronized (self) { _socket=fd; }
    struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;
    address.sin_port=htons(_port);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    int connected=connect(fd,(struct sockaddr *)&address,sizeof(address));
    int error=connected<0?errno:0;
    if (connected<0 && error==EINPROGRESS) {
        struct pollfd p={fd,POLLOUT,0};
        if (poll(&p,1,2000)>0) { socklen_t n=sizeof(error);getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&n); }
        else error=ETIMEDOUT;
    }
    if (error || atomic_load(&_generation)!=generation) {
        [self message:@"手机采集服务未启动；安装 rootless 服务包后，打开 AppleLive USB 查看状态"
            state:@"error" code:error generation:generation];
        [self closeSocket:fd];return;
    }
    NSData *start=[NSJSONSerialization dataWithJSONObject:@{@"command":@"start",@"token":token,@"version":@1} options:0 error:nil];
    if (!ALUVCSendMessage(fd,'C',start,2)) {
        [self message:@"无法向采集服务发起连接" state:@"error" code:errno generation:generation];
        [self closeSocket:fd];return;
    }
    NSData *credit=[NSJSONSerialization dataWithJSONObject:@{@"command":@"next"} options:0 error:nil];
    CFAbsoluteTime last=CFAbsoluteTimeGetCurrent();
    BOOL received=NO,failed=NO;
    while (atomic_load(&_generation)==generation) {
        @autoreleasepool {
            char type=0;NSData *data=nil;
            int result=ALUVCReadMessage(fd,&type,&data,2);
            if (!result && CFAbsoluteTimeGetCurrent()-last<6) continue;
            if (result!=1) { failed=YES;break; }
            last=CFAbsoluteTimeGetCurrent();
            if (atomic_load(&_generation)!=generation) break;
            if (type=='S') {
                NSDictionary *status=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![status isKindOfClass:NSDictionary.class]) { failed=YES;break; }
                NSString *state=status[@"state"],*message=status[@"message"],*report=status[@"diagnostic"];
                if (![state isKindOfClass:NSString.class] || ![message isKindOfClass:NSString.class]) { failed=YES;break; }
                if ([report isKindOfClass:NSString.class]) self.serviceReport=[report substringToIndex:MIN(report.length,14000)];
                if ([state isEqualToString:@"error"]) {
                    [self message:message state:state code:[status[@"code"] respondsToSelector:@selector(intValue)]?[status[@"code"] intValue]:-1 generation:generation];
                    break;
                }
                if (!received) [self message:message state:@"opening" code:0 generation:generation];
            } else if (type=='V') {
                CVPixelBufferRef pixel=ALUVCCopyWireFrame(data);
                if (!pixel) {
                    [self message:@"采集服务发来的帧无法解码，请复制连接诊断" state:@"error" code:-20 generation:generation];break;
                }
                if (atomic_load(&_generation)==generation) {
                    void (^handler)(CVPixelBufferRef)=self.onFrame;
                    if (handler) handler(pixel);
                    if (!received) [self message:@"外接相机画面已接入 · 手机服务采集" state:@"playing" code:0 generation:generation];
                    received=YES;
                }
                CVPixelBufferRelease(pixel);
                if (!ALUVCSendMessage(fd,'C',credit,2)) { failed=YES;break; }
            } else { failed=YES;break; }
        }
    }
    if (failed) [self message:@"手机采集服务连接已断开，请点击连接 / 重试" state:@"error" code:-21 generation:generation];
    [self closeSocket:fd];
}
- (void)closeSocket:(int)fd {
    @synchronized (self) { if (_socket==fd) _socket=-1;close(fd); }
}
@end
