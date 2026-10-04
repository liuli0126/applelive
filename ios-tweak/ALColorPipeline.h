#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

CGColorSpaceRef ALBT709ColorSpace(void);
CIContext *ALCreateVideoRenderContext(void);
CIImage *ALVideoImageFromPixelBuffer(CVPixelBufferRef pixelBuffer);
void ALSetVideoColorAttachments(CVPixelBufferRef pixelBuffer,
                                CFStringRef primaries,
                                CFStringRef transferFunction,
                                CFStringRef yCbCrMatrix);
void ALSetDefaultVideoColorAttachments(CVPixelBufferRef pixelBuffer);
void ALRenderVideoImage(CIContext *context, CIImage *image,
                        CVPixelBufferRef target, CGRect bounds);
