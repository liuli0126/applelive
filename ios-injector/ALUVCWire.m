#import "ALUVCWire.h"
#import "ALUVCFrame.h"
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>

static const size_t ALUVCMaxMessage = 8 * 1024 * 1024 + 32;
static uint32_t read32(const uint8_t *p) { return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]; }
static void write32(uint8_t *p,uint32_t n) { p[0]=n>>24;p[1]=n>>16;p[2]=n>>8;p[3]=n; }
static BOOL dimensions(size_t n,uint32_t w,uint32_t h,uint32_t stride,uint32_t format) {
    if (!n || n > 8*1024*1024 || w<2 || h<2 || w>1920 || h>1920 || (uint64_t)w*h>1920*1080) return NO;
    if (format == ALUVCJPEG) return n>=4;
    if ((format!=ALUVCYUY2 && format!=ALUVCUYVY) || w%2) return NO;
    if (!stride) stride=w*2;
    return stride>=w*2 && stride<=8*1024*1024 && (uint64_t)(h-1)*stride + w*2<=n;
}
NSData *ALUVCPackFrame(const void *bytes,size_t length,uint32_t w,uint32_t h,uint32_t stride,uint32_t format) {
    if (!bytes || !dimensions(length,w,h,stride,format)) return nil;
    if (format==ALUVCJPEG && (((const uint8_t *)bytes)[0]!=0xff || ((const uint8_t *)bytes)[1]!=0xd8)) return nil;
    NSMutableData *packet=[NSMutableData dataWithLength:24];
    uint8_t *p=packet.mutableBytes; memcpy(p,"UVF1",4);
    write32(p+4,format);write32(p+8,w);write32(p+12,h);write32(p+16,stride);write32(p+20,(uint32_t)length);
    [packet appendBytes:bytes length:length];return packet;
}
CVPixelBufferRef ALUVCCopyWireFrame(NSData *packet) {
    if (packet.length<24 || packet.length>ALUVCMaxMessage) return NULL;
    const uint8_t *p=packet.bytes;
    if (memcmp(p,"UVF1",4)) return NULL;
    uint32_t format=read32(p+4),w=read32(p+8),h=read32(p+12),stride=read32(p+16),length=read32(p+20);
    if (length!=packet.length-24 || !dimensions(length,w,h,stride,format)) return NULL;
    return ALCopyUVCFrame(p+24,length,w,h,stride,format==ALUVCJPEG,format==ALUVCUYVY);
}
BOOL ALUVCValidToken(NSString *token) {
    if (![token isKindOfClass:NSString.class] || token.length!=64) return NO;
    for (NSUInteger i=0;i<64;i++) {
        unichar c=[token characterAtIndex:i];
        if (!((c>='0' && c<='9') || (c>='a' && c<='f'))) return NO;
    }
    return YES;
}
BOOL ALUVCTokensEqual(NSString *left,NSString *right) {
    if (!ALUVCValidToken(left) || !ALUVCValidToken(right)) return NO;
    unsigned diff=0;
    for (NSUInteger i=0;i<64;i++) diff|=[left characterAtIndex:i] ^ [right characterAtIndex:i];
    return diff==0;
}
static double now(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9; }
void ALUVCConfigureSocket(int fd) {
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL,0)|O_NONBLOCK);
    int one=1;
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
}
static int transfer(int fd,void *bytes,size_t size,BOOL writing,double deadline) {
    size_t offset=0;
    while (offset<size) {
        double remaining=deadline-now();
        if (remaining<=0) return offset ? -1 : 0;
        struct pollfd p={fd,writing?POLLOUT:POLLIN,0};
        int ready=poll(&p,1,(int)MAX(1,MIN(2000,remaining*1000)));
        if (ready<0 && errno==EINTR) continue;
        if (ready<0 || p.revents&POLLNVAL) return -1;
        if (!ready) continue;
        ssize_t n=writing?send(fd,(uint8_t *)bytes+offset,size-offset,0):recv(fd,(uint8_t *)bytes+offset,size-offset,0);
        if (n<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)) continue;
        if (n<=0) return -1;
        offset+=(size_t)n;
    }
    return 1;
}
BOOL ALUVCSendMessage(int fd,char type,NSData *data,double timeout) {
    if (!data || data.length+1>ALUVCMaxMessage) return NO;
    uint8_t header[5];write32(header,(uint32_t)data.length+1);header[4]=type;
    double deadline=now()+timeout;
    return transfer(fd,header,5,YES,deadline)==1 &&
        (!data.length || transfer(fd,(void *)data.bytes,data.length,YES,deadline)==1);
}
int ALUVCReadMessage(int fd,char *type,NSData **data,double timeout) {
    uint8_t header[5];double deadline=now()+timeout;
    int result=transfer(fd,header,5,NO,deadline);
    if (result!=1) return result;
    uint32_t n=read32(header);
    if (n<1 || n>ALUVCMaxMessage || (header[4]!='S' && header[4]!='C' && header[4]!='V') ||
        (header[4]!='V' && n>32768)) return -1;
    NSMutableData *body=[NSMutableData dataWithLength:n-1];
    if (body.length && transfer(fd,body.mutableBytes,body.length,NO,deadline)!=1) return -1;
    *type=header[4];*data=body;return 1;
}
