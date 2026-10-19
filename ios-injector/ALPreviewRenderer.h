#import <AVFoundation/AVFoundation.h>

// Called on the main thread. A missing frame means "try again", while an
// inactive/changed source explicitly removes the previously displayed image.
void ALUpdatePreviewLayer(AVSampleBufferDisplayLayer *layer, CVPixelBufferRef pixel,
                          uint64_t generation, BOOL active);
