#import "ALSourceSettings.h"
#import "ALConnection.h"

static void check(BOOL passed, NSString *message) {
    if (!passed) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSString *rtmp = @"rtmp://192.168.1.45:1935/live/applelive";
        NSString *rtsp = @"rtsp://192.168.1.45:8554/live/applelive";
        NSDictionary *migrated = ALMigrateMediaSource(@{@"kind": @"computer"}, rtmp);
        check([migrated[@"kind"] isEqual:@"network"] && [migrated[@"url"] isEqual:rtmp] &&
              [migrated[@"loop"] boolValue], @"Old computer source must migrate to Detection with looping enabled");
        migrated = ALMigrateMediaSource(@{@"kind": @"computer", @"url": rtsp, @"loop": @NO}, rtmp);
        check([migrated[@"url"] isEqual:rtsp] && ![migrated[@"loop"] boolValue], @"Migration must preserve RTSP and explicit loop preference");
        for (NSDictionary *saved in @[
            @{@"kind": @"local", @"file": @"clip.mp4", @"loop": @NO},
            @{@"kind": @"network", @"url": rtsp, @"loop": @YES},
            @{@"kind": @"usb", @"loop": @YES}
        ]) check([ALMigrateMediaSource(saved, rtmp) isEqual:saved], @"Existing local, network and USB sources must remain intact");
        migrated = ALMigrateMediaSource(nil, @"");
        check([migrated[@"kind"] isEqual:@"network"] && [migrated[@"url"] isEqual:@""], @"A fresh install without a host must wait for a stream URL");
        for (NSString *url in @[rtmp, rtsp, @"rtmps://example.com/live/key", @"https://example.com/a.m3u8", @"http://192.168.1.45/a.mp4"])
            check(ALValidStreamURL(url), @"A supported stream scheme was rejected");
        for (NSString *url in @[@"ws://192.168.1.45:8765", @"192.168.1.45:8765", @"rtmp://", @""])
            check(!ALValidStreamURL(url), @"A non-stream address was accepted");
        check(!ALValidStreamURL(nil), @"A nil address was accepted");
        check(ALConnectionAddresses(@{@"host": @"192.168.1.45", @"port": @8765}).count == 0,
              @"The standalone plugin must never start the old LAN client");
        puts("Source migration, stream schemes and removal of duplicate LAN route passed");
    }
    return 0;
}
