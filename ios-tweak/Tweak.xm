#import <Foundation/Foundation.h>
#import "ALVirtualCamera.h"
#import "ALFloatingPanel.h"

__attribute__((constructor))
static void AppleLiveInit(void) {
    @autoreleasepool {
        // The package filter limits injection to mediaserverd and camera apps.
        // Initializing in every filtered process is required for
        // the AVCapture delegate fallback to work in third-party live apps.
        [[ALVirtualCamera sharedInstance] start];
        [ALFloatingPanel installForCurrentApplication];
    }
}
