#import "ALUVCHostServer.h"
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        uint16_t port=8767;
        NSString *directory=@"/var/mobile/Library/AppleLiveUVC";
#ifdef AL_UVC_SERVICE_TEST
        if (argc==3) { port=(uint16_t)atoi(argv[1]);directory=[NSString stringWithUTF8String:argv[2]]; }
#else
        (void)argc;(void)argv;
#endif
        return ALUVCRunHost(port,directory);
    }
}
