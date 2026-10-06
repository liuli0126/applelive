#import <CoreImage/CoreImage.h>

// Strength is 0–100; 75 preserves the original fixed effect. Off/0 bypass it.
CIImage *ALApplyFisheye(CIImage *image, BOOL enabled, CGFloat strength);
