#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

enum { ALUVCJPEG = 1, ALUVCYUY2 = 2, ALUVCUYVY = 3 };
NSData *ALUVCPackFrame(const void *bytes, size_t length, uint32_t width, uint32_t height,
                      uint32_t stride, uint32_t format);
CVPixelBufferRef ALUVCCopyWireFrame(NSData *packet) CF_RETURNS_RETAINED;
BOOL ALUVCValidToken(NSString *token);
BOOL ALUVCTokensEqual(NSString *left, NSString *right);

// Loopback-only, length-delimited service protocol. S=status JSON, V=UVC frame,
// C=client JSON (authenticated start or next-frame credit). No filesystem RPC.
BOOL ALUVCSendMessage(int fd, char type, NSData *data, double timeout);
// 1 = complete, 0 = no bytes before deadline, -1 = EOF/error/partial message.
int ALUVCReadMessage(int fd, char *type, NSData **data, double timeout);
void ALUVCConfigureSocket(int fd);
