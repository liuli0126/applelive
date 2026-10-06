#import <CoreImage/CoreImage.h>

// Same extent and color semantics as the input; disabled returns it unchanged.
CIImage *ALApplyFisheye(CIImage *image, BOOL enabled);
