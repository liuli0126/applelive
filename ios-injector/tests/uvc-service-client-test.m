#import "ALUVCServiceClient.h"
#include <stdatomic.h>
#include <unistd.h>
static void check(BOOL ok,const char *why) { if (!ok) { fprintf(stderr,"FAIL %s\n",why);exit(1); } }
static BOOL awaitState(ALUVCServiceClient *client,NSString *state,double seconds) {
    CFAbsoluteTime end=CFAbsoluteTimeGetCurrent()+seconds;
    while(CFAbsoluteTimeGetCurrent()<end) { if([client.status[@"state"] isEqual:state]) return YES;usleep(10000); }
    fprintf(stderr,"State: %s\n",client.status.description.UTF8String);return NO;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        check(argc==3,"port and token-file arguments");
        NSString *token=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[2]] encoding:NSASCIIStringEncoding error:nil];
        check([ALUVCServiceClient saveConnectionCode:token],"pairing token accepted");
        ALUVCServiceClient *client=[[ALUVCServiceClient alloc] initWithPort:atoi(argv[1])];
        __block atomic_int frames;atomic_init(&frames,0);
        client.onFrame=^(CVPixelBufferRef frame) {
            check(CVPixelBufferGetWidth(frame)==4 && CVPixelBufferGetHeight(frame)==2,"frame dimensions preserved");
            CVPixelBufferLockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
            uint8_t *p=CVPixelBufferGetBaseAddress(frame);
            check(p[0]==0 && p[4]==255,"raw UVC to owned BGRA");
            CVPixelBufferUnlockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);atomic_fetch_add(&frames,1);
        };
        [client start];check(awaitState(client,@"playing",3),"paired service delivers frame");
        usleep(100000);[client stop];usleep(200000);int count=atomic_load(&frames);usleep(100000);
        check(atomic_load(&frames)==count,"disconnect cancels media delivery");
        [client start];check(awaitState(client,@"playing",3),"service reconnect");[client stop];usleep(200000);
        NSMutableString *wrong=[token mutableCopy];[wrong replaceCharactersInRange:NSMakeRange(0,1) withString:[token hasPrefix:@"a"]?@"b":@"a"];
        [ALUVCServiceClient saveConnectionCode:wrong];[client start];check(awaitState(client,@"error",3),"bad pairing rejected");
        check([client.status[@"code"] intValue]==401,"pairing error retained");[client stop];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLive.UVCServiceToken.v1"];
        puts("PASS paired UVC service client, owned video, disconnect, reconnect and bad-token rejection");
    }
    return 0;
}
