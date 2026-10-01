#import <Foundation/Foundation.h>
#import "ALConnection.h"
#include <stdio.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: AppleLiveSetup <IPv4[:port]>\n");
            return 2;
        }
        NSString *host = nil;
        NSNumber *port = nil;
        NSString *address = [NSString stringWithUTF8String:argv[1]];
        if (!ALParseComputerAddress(address, &host, &port)) {
            fprintf(stderr, "Invalid computer address\n");
            return 2;
        }
        NSMutableDictionary *settings = [ALConnectionSettings() mutableCopy];
        settings[@"host"] = host;
        settings[@"port"] = port;
        settings[@"paused"] = @NO;
        if (!ALPublishConnection(settings)) {
            fprintf(stderr, "Failed to publish connection settings\n");
            return 1;
        }
        NSData *result = [NSJSONSerialization dataWithJSONObject:settings options:0 error:NULL];
        fwrite(result.bytes, 1, result.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
