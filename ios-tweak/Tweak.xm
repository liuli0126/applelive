#import <Foundation/Foundation.h>
#import "ALVirtualCamera.h"

__attribute__((constructor))
static void AppleLiveInit(void) {
    @autoreleasepool {
        // The package filter limits injection to mediaserverd, SpringBoard and
        // UIKit clients. Initializing in every filtered process is required for
        // the AVCapture delegate fallback to work in third-party live apps.
        [[ALVirtualCamera sharedInstance] start];
    }
}
