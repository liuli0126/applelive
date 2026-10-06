#import "ALUVCHostServer.h"
#import "ALExternalCamera.h"
#import "ALUVCWire.h"
#import <Security/Security.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>

static volatile sig_atomic_t stopping;
static void terminateHost(int signal) { (void)signal;stopping=1; }
@interface ALUVCLatestPacket : NSObject
@property(nonatomic) NSData *packet;
@end
@implementation ALUVCLatestPacket
@end

static NSString *readToken(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if (fd<0) return nil;
    struct stat st;uint8_t bytes[64];
    BOOL valid=fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==getuid() && st.st_size==64;
    ssize_t n=valid?read(fd,bytes,sizeof(bytes)):-1;close(fd);
    if (n!=64) return nil;
    NSString *token=[[NSString alloc] initWithBytes:bytes length:64 encoding:NSASCIIStringEncoding];
    return ALUVCValidToken(token)?token:nil;
}
static NSString *createToken(NSString *directory) {
    NSError *error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
         attributes:@{NSFilePosixPermissions:@0700} error:&error]) return nil;
    NSString *path=[directory stringByAppendingPathComponent:@"connection-token"];
    NSString *token=readToken(path);if (token) return token;
    uint8_t random[32];if (SecRandomCopyBytes(kSecRandomDefault,sizeof(random),random)!=errSecSuccess) return nil;
    NSMutableString *generated=[NSMutableString new];
    for (size_t i=0;i<sizeof(random);i++) [generated appendFormat:@"%02x",random[i]];
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if (fd<0) return errno==EEXIST?readToken(path):nil;
    ssize_t n=write(fd,generated.UTF8String,64);fsync(fd);close(fd);
    if (n!=64) { unlink(path.fileSystemRepresentation);return nil; }
    return generated;
}
static BOOL sendStatus(int fd,NSDictionary *status,NSString *diagnostic) {
    NSMutableDictionary *message=[status mutableCopy];
    message[@"version"]=@1;
    message[@"diagnostic"]=diagnostic ?: @"";
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    return bytes && bytes.length<32000 && ALUVCSendMessage(fd,'S',bytes,2);
}
static NSDictionary *receiveCommand(int fd,double timeout) {
    char type=0;NSData *bytes=nil;
    if (ALUVCReadMessage(fd,&type,&bytes,timeout)!=1 || type!='C' || bytes.length>4096) return nil;
    id command=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    return [command isKindOfClass:NSDictionary.class]?command:nil;
}
static void serve(int fd,NSString *token) {
    ALUVCConfigureSocket(fd);
    NSDictionary *request=receiveCommand(fd,2);
    if (!request) return;
    if (![request[@"command"] isEqual:@"start"] || ![request[@"version"] isEqual:@1] ||
        !ALUVCTokensEqual(request[@"token"],token)) {
        sendStatus(fd,@{@"state":@"error",@"message":@"服务配对失败，请在 AppleLive USB 中重新复制连接码并配对",@"code":@401},nil);
        return;
    }
    ALExternalCamera *camera=[ALExternalCamera new];
    ALUVCLatestPacket *latest=[ALUVCLatestPacket new];
    camera.onRawFrame=^(NSData *packet) { @synchronized (latest) { latest.packet=packet; } };
    BOOL healthy=sendStatus(fd,@{@"state":@"opening",@"message":@"手机采集服务已连接，正在识别采集卡…",@"code":@0},nil);
    if (!healthy) return;
    [camera start];
    fprintf(stderr,"[AppleLive UVC] authenticated capture session started\n");
    BOOL credit=YES;
    CFAbsoluteTime lastStatus=0,lastCredit=CFAbsoluteTimeGetCurrent();
    while (!stopping && healthy) {
        @autoreleasepool {
            struct pollfd event={fd,POLLIN,0};int available=poll(&event,1,10);
            if (available<0) { if (errno==EINTR) continue;break; }
            if (available>0) {
                NSDictionary *command=receiveCommand(fd,2);
                if (![command[@"command"] isEqual:@"next"]) break;
                credit=YES;lastCredit=CFAbsoluteTimeGetCurrent();
            }
            CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
            if (now-lastStatus>=1) {
                NSDictionary *status=camera.status;
                healthy=sendStatus(fd,status,camera.diagnosticReport);lastStatus=now;
                if ([status[@"state"] isEqual:@"error"]) break;
            }
            if (!healthy) break;
            if (credit) {
                NSData *packet=nil;
                @synchronized (latest) { packet=latest.packet;latest.packet=nil; }
                if (packet) {
                    healthy=ALUVCSendMessage(fd,'V',packet,2);credit=NO;lastCredit=now;
                }
            } else if (now-lastCredit>5) break;
        }
    }
    [camera stopAndWait];camera.onRawFrame=nil;
    @synchronized (latest) { latest.packet=nil; }
    fprintf(stderr,"[AppleLive UVC] capture session closed\n");
}
int ALUVCRunHost(uint16_t port,NSString *directory) {
    NSString *token=createToken(directory);
    if (!token) { fprintf(stderr,"Unable to load private pairing token\n");return 1; }
    int listener=socket(AF_INET,SOCK_STREAM,0);if (listener<0) return 2;
    int one=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;
    address.sin_port=htons(port);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if (bind(listener,(struct sockaddr *)&address,sizeof(address))<0 || listen(listener,2)<0) { close(listener);return 3; }
    signal(SIGTERM,terminateHost);signal(SIGINT,terminateHost);signal(SIGPIPE,SIG_IGN);
    NSString *pidPath=[directory stringByAppendingPathComponent:@"service-pid"];
    [[NSString stringWithFormat:@"%d",getpid()] writeToFile:pidPath atomically:YES encoding:NSASCIIStringEncoding error:nil];
    fprintf(stderr,"[AppleLive UVC] ready on phone loopback, no capture until paired request\n");
    while (!stopping) {
        @autoreleasepool {
            struct pollfd p={listener,POLLIN,0};
            int ready=poll(&p,1,500);
            if (ready<0 && errno!=EINTR) break;
            if (ready<=0) continue;
            int client=accept(listener,NULL,NULL);if (client<0) continue;
            serve(client,token);shutdown(client,SHUT_RDWR);close(client);
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:pidPath error:nil];close(listener);return 0;
}
