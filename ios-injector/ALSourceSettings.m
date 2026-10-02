#import "ALSourceSettings.h"

BOOL ALValidStreamURL(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    return [@[@"rtmp", @"rtmps", @"rtsp", @"http", @"https"] containsObject:url.scheme.lowercaseString] && url.host.length > 0;
}

NSDictionary *ALMigrateMediaSource(NSDictionary *saved, NSString *defaultURL) {
    NSMutableDictionary *source = [saved mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!source[@"loop"]) source[@"loop"] = @YES;
    NSString *kind = source[@"kind"];
    // The former computer source was the second LAN path. Upgrade it to Detection,
    // retaining a previously entered stream URL (including RTSP) when available.
    if (!kind || [kind isEqualToString:@"computer"]) {
        source[@"kind"] = @"network";
        if (!ALValidStreamURL(source[@"url"])) source[@"url"] = ALValidStreamURL(defaultURL) ? defaultURL : @"";
    }
    return source;
}
