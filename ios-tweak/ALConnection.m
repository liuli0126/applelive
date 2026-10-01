#import "ALConnection.h"
#import <arpa/inet.h>
#import <notify.h>

static const char *kNotification = "com.applelive.connection.v1";
static const uint64_t kMagic = UINT64_C(0xa11c000000000000);

static int ALConnectionToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notify_register_check(kNotification, &token); });
    return token;
}

BOOL ALParseComputerAddress(NSString *address, NSString **host, NSNumber **port) {
    NSArray *parts = [[address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     componentsSeparatedByString:@":"];
    if (parts.count < 1 || parts.count > 2) return NO;
    struct in_addr ip;
    if (inet_pton(AF_INET, [parts[0] UTF8String], &ip) != 1) return NO;
    uint32_t value = ntohl(ip.s_addr);
    if ((value >> 24) == 0 || (value >> 24) == 127 || (value >> 24) >= 224) return NO;
    NSString *portText = parts.count == 2 ? parts[1] : @"8765";
    if (!portText.length || [portText rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    NSInteger number = portText.integerValue;
    if (number < 1 || number > 65535) return NO;
    if (host) *host = parts[0];
    if (port) *port = @(number);
    return YES;
}

static NSDictionary *ALDecodeConnection(uint64_t value) {
    if ((value & UINT64_C(0xfffc000000000000)) != kMagic) return nil;
    unsigned mode = (value >> 48) & 3;
    unsigned port = (value >> 32) & 0xffff;
    if (mode > 2 || port == 0) return nil;
    struct in_addr ip = { .s_addr = htonl((uint32_t)value) };
    char host[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &ip, host, sizeof(host));
    return @{@"mode": @"auto", @"host": @(host), @"port": @(port)};
}

NSDictionary *ALConnectionSettings(void) {
    uint64_t state = 0;
    int token = ALConnectionToken();
    if (token >= 0 && notify_get_state(token, &state) == NOTIFY_STATUS_OK) {
        NSDictionary *settings = ALDecodeConnection(state);
        if (settings) return settings;
    }
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"AppleLive.Connection.v1"];
    if (saved) {
        NSMutableDictionary *settings = [saved mutableCopy];
        settings[@"mode"] = @"auto"; // Migrate old manually selected phone modes.
        return settings;
    }
    // Import the existing computer address on upgrade; no device-specific default.
    for (NSString *path in @[@"/var/mobile/Library/Preferences/com.applelive.tweak.plist",
                            @"/var/jb/var/mobile/Library/Preferences/com.applelive.tweak.plist"]) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *servers = [prefs[@"servers"] isKindOfClass:NSArray.class] ? prefs[@"servers"] : @[];
        if ([prefs[@"server"] isKindOfClass:NSString.class]) servers = [servers arrayByAddingObject:prefs[@"server"]];
        for (id server in servers) {
            NSString *host; NSNumber *port;
            if ([server isKindOfClass:NSString.class] && ALParseComputerAddress(server, &host, &port))
                return @{@"mode": @"auto", @"host": host, @"port": port};
        }
    }
    return @{@"mode": @"auto", @"host": @"0.0.0.0", @"port": @8765};
}

BOOL ALPublishConnection(NSDictionary *settings) {
    NSMutableDictionary *automatic = [settings mutableCopy];
    automatic[@"mode"] = @"auto";
    settings = automatic;
    NSUInteger mode = 0;
    struct in_addr ip;
    NSString *host = settings[@"host"];
    NSInteger port = [settings[@"port"] integerValue];
    if (mode == NSNotFound || ![host isKindOfClass:NSString.class] ||
        inet_pton(AF_INET, host.UTF8String, &ip) != 1 || port < 1 || port > 65535) return NO;
    if (mode == 2 && !ALParseComputerAddress([NSString stringWithFormat:@"%@:%ld", host, (long)port], NULL, NULL)) return NO;
    int token = ALConnectionToken();
    uint64_t state = kMagic | ((uint64_t)mode << 48) | ((uint64_t)port << 32) | ntohl(ip.s_addr);
    if (token < 0 || notify_set_state(token, state) != NOTIFY_STATUS_OK) return NO;
    [NSUserDefaults.standardUserDefaults setObject:settings forKey:@"AppleLive.Connection.v1"];
    return notify_post(kNotification) == NOTIFY_STATUS_OK;
}

void ALObserveConnection(void (^handler)(NSDictionary *settings)) {
    int token = -1;
    notify_register_dispatch(kNotification, &token, dispatch_get_main_queue(), ^(int registered) {
        uint64_t value = 0;
        if (notify_get_state(registered, &value) != NOTIFY_STATUS_OK) return;
        NSDictionary *settings = ALDecodeConnection(value);
        if (settings) handler(settings);
    });
}

void ALPersistConnection(NSDictionary *settings) {
    // mediaserverd is sandboxed: its preferences daemon can persist this,
    // whereas direct writes to a new shared Preferences file are denied.
    [NSUserDefaults.standardUserDefaults setObject:settings forKey:@"AppleLive.Connection.v1"];
}

NSArray<NSString *> *ALConnectionAddresses(NSDictionary *settings) {
    NSMutableArray *addresses = [NSMutableArray array];
    [addresses addObject:@"127.0.0.1:8765"];
    NSString *address = [NSString stringWithFormat:@"%@:%@", settings[@"host"], settings[@"port"]];
    if (ALParseComputerAddress(address, NULL, NULL)) [addresses addObject:address];
    return addresses;
}
