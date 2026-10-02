#import <Foundation/Foundation.h>
#import "ALConnection.h"
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSString *host = nil;
        NSString *url = @"rtmp://192.168.1.45:1935/live/applelive";
        if (!ALParseRTMPStreamURL(url, &host) || ![host isEqualToString:@"192.168.1.45"]) return 1;
        if (![ALRTMPStreamURL(@{@"host": host, @"port": @8765}) isEqualToString:url]) return 2;
        if (![ALRTMPStreamURL(@{@"host": host, @"port": @8765, @"streamURL": url}) isEqualToString:url]) return 3;
        for (NSString *invalid in @[
            @"192.168.1.45:8765", @"ws://192.168.1.45:8765",
            @"rtmp://127.0.0.1:1935/live/applelive", @"rtmp://192.168.1.45/live/applelive",
            @"rtmp://192.168.1.45:1935/", @"rtmp://192.168.1.45:1935/live/applelive?x=1",
        ]) if (ALParseRTMPStreamURL(invalid, NULL)) return 4;
        puts("RTMP computer address parsing passed");
    }
    return 0;
}
