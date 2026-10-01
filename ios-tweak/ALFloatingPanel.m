#import "ALFloatingPanel.h"
#import "ALControls.h"
#import "ALConnection.h"
#import <UIKit/UIKit.h>
#import <os/log.h>

@interface ALPassThroughWindow : UIWindow
@end
@implementation ALPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self || hit == self.rootViewController.view ? nil : hit;
}
@end

@interface ALPanelViewController : UIViewController
@property(nonatomic, copy) void (^onLayout)(void);
@end
@implementation ALPanelViewController
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.onLayout) self.onLayout();
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface ALFloatingPanel ()
@property(nonatomic) ALPassThroughWindow *window;
@property(nonatomic) UIButton *bubble;
@property(nonatomic) UIView *panel;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UILabel *directionLabel;
@property(nonatomic) UILabel *hintLabel;
@property(nonatomic) UISwitch *enabledSwitch;
@property(nonatomic) UISwitch *mirrorSwitch;
@property(nonatomic) UISwitch *audioSwitch;
@property(nonatomic) UISegmentedControl *fitControl;
@property(nonatomic) UISegmentedControl *connectionControl;
@property(nonatomic) UIButton *addressButton;
@property(nonatomic) NSMutableDictionary *connection;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic) NSMutableDictionary *controls;
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL published;
@property(nonatomic) CGPoint bubbleFraction;
@end

@implementation ALFloatingPanel

+ (void)installForCurrentApplication {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    if (![@[@"com.apple.camera", @"com.ss.iphone.ugc.Aweme", @"com.zhiliaoapp.musically"] containsObject:bundle]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static ALFloatingPanel *controller;
        if (controller) return;
        controller = [ALFloatingPanel new];
        controller.controls = [ALLoadAppControls() mutableCopy];
        controller.connection = [ALConnectionSettings() mutableCopy];
        NSDictionary *position = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"AppleLive.BubblePosition.v1"];
        controller.bubbleFraction = position ? CGPointMake([position[@"x"] doubleValue], [position[@"y"] doubleValue])
                                             : CGPointMake(1, 0.22);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:controller selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:controller selector:@selector(willResign:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSTimer scheduledTimerWithTimeInterval:1 target:controller selector:@selector(refresh) userInfo:nil repeats:YES];
        [controller refresh];
    });
}

- (void)becameActive:(NSNotification *)notification {
    self.published = NO;
    [self refresh];
    (void)notification;
}

- (void)willResign:(NSNotification *)notification {
    [self restoreKeyWindow];
    self.window.hidden = YES;
    self.expanded = NO;
    self.published = NO;
    (void)notification;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.85;
    return label;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    button.layer.cornerRadius = 12;
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIStackView *)row:(NSArray<UIView *> *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return row;
}

- (UISwitch *)makeSwitch:(NSString *)label {
    UISwitch *toggle = [UISwitch new];
    toggle.onTintColor = [UIColor colorWithRed:0.22 green:0.56 blue:1 alpha:1];
    toggle.accessibilityLabel = label;
    [toggle addTarget:self action:@selector(controlsChanged:) forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (void)buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    ALPassThroughWindow *window = scene ? [[ALPassThroughWindow alloc] initWithWindowScene:scene]
                                      : [[ALPassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window = window;
    window.frame = UIScreen.mainScreen.bounds;
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelAlert + 1;
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    ALPanelViewController *root = [ALPanelViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    __weak typeof(self) weakSelf = self;
    root.onLayout = ^{ [weakSelf layoutControls]; };

    self.bubble = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bubble.backgroundColor = [UIColor colorWithRed:0.12 green:0.39 blue:0.91 alpha:0.96];
    self.bubble.tintColor = UIColor.whiteColor;
    self.bubble.layer.cornerRadius = 28;
    self.bubble.layer.shadowColor = UIColor.blackColor.CGColor;
    self.bubble.layer.shadowOpacity = 0.3;
    self.bubble.layer.shadowRadius = 8;
    self.bubble.layer.shadowOffset = CGSizeMake(0, 3);
    [self.bubble setImage:[UIImage systemImageNamed:@"video.fill"] forState:UIControlStateNormal];
    self.bubble.accessibilityLabel = @"AppleLive 画面控制，点按打开";
    [self.bubble addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBubble:)]];
    [root.view addSubview:self.bubble];

    self.panel = [UIView new];
    self.panel.backgroundColor = [UIColor colorWithRed:0.075 green:0.085 blue:0.11 alpha:0.98];
    self.panel.layer.cornerRadius = 22;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    self.panel.layer.borderWidth = 1;
    self.panel.clipsToBounds = YES;
    [root.view addSubview:self.panel];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.panel addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.panel.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor],
    ]];

    UILabel *title = [self label:@"AppleLive" size:22];
    self.statusLabel = [self label:@"正在连接电脑…" size:13];
    self.statusLabel.textColor = UIColor.lightGrayColor;
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.statusLabel]];
    heading.axis = UILayoutConstraintAxisVertical;
    heading.spacing = 4;
    UIButton *close = [self button:@"收起" action:@selector(togglePanel)];
    [close.widthAnchor constraintEqualToConstant:58].active = YES;
    self.enabledSwitch = [self makeSwitch:@"启用插件"];
    self.connectionControl = [[UISegmentedControl alloc] initWithItems:@[@"自动", @"USB", @"局域网"]];
    self.connectionControl.accessibilityLabel = @"连接方式";
    self.connectionControl.selectedSegmentTintColor = [UIColor colorWithRed:0.18 green:0.43 blue:0.87 alpha:1];
    [self.connectionControl.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.connectionControl addTarget:self action:@selector(connectionChanged) forControlEvents:UIControlEventValueChanged];
    self.addressButton = [self button:@"设置电脑地址" action:@selector(editAddress)];
    [self syncConnection];
    self.mirrorSwitch = [self makeSwitch:@"左右镜像"];
    self.audioSwitch = [self makeSwitch:@"电脑声音"];
    self.directionLabel = [self label:@"画面方向 · 0°" size:15];
    UIButton *reset = [self button:@"重置" action:@selector(resetControls)];
    [reset.widthAnchor constraintEqualToConstant:58].active = YES;
    UIStackView *rotation = [self row:@[[self button:@"左转 90°" action:@selector(rotateLeft)],
                                      [self button:@"右转 90°" action:@selector(rotateRight)]]];
    rotation.distribution = UIStackViewDistributionFillEqually;
    self.fitControl = [[UISegmentedControl alloc] initWithItems:@[@"完整画面", @"铺满画面"]];
    self.fitControl.selectedSegmentTintColor = [UIColor colorWithRed:0.18 green:0.43 blue:0.87 alpha:1];
    [self.fitControl.heightAnchor constraintEqualToConstant:44].active = YES;
    self.fitControl.accessibilityLabel = @"画面比例";
    [self.fitControl addTarget:self action:@selector(controlsChanged:) forControlEvents:UIControlEventValueChanged];
    self.hintLabel = [self label:@"设置会自动保存，只对当前 App 生效。" size:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textColor = UIColor.lightGrayColor;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self row:@[heading, close]],
        [self label:@"连接方式" size:15], self.connectionControl, self.addressButton,
        [self row:@[[self label:@"启用插件" size:16], self.enabledSwitch]],
        [self row:@[self.directionLabel, reset]], rotation,
        [self row:@[[self label:@"左右镜像" size:16], self.mirrorSwitch]],
        self.fitControl,
        [self row:@[[self label:@"电脑声音" size:16], self.audioSwitch]], self.hintLabel,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 12;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:18],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-18],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36],
    ]];
    [self syncControls];
    [self layoutControls];
    window.hidden = NO; // Keep the host application's key window and keyboard focus.
    os_log(OS_LOG_DEFAULT, "[AppleLive] floating controls ready in %{public}@", NSBundle.mainBundle.bundleIdentifier);
}

- (CGRect)usableBounds {
    UIView *root = self.window.rootViewController.view;
    return UIEdgeInsetsInsetRect(root.bounds, UIEdgeInsetsMake(root.safeAreaInsets.top + 10,
        root.safeAreaInsets.left + 10, root.safeAreaInsets.bottom + 10, root.safeAreaInsets.right + 10));
}

- (void)layoutControls {
    if (!self.window) return;
    CGRect safe = [self usableBounds];
    CGFloat availableX = MAX(0, safe.size.width - 56);
    CGFloat availableY = MAX(0, safe.size.height - 56);
    self.bubble.frame = CGRectMake(safe.origin.x + availableX * MAX(0, MIN(1, self.bubbleFraction.x)),
                                  safe.origin.y + availableY * MAX(0, MIN(1, self.bubbleFraction.y)), 56, 56);
    CGFloat width = MIN(336, safe.size.width);
    CGFloat height = MIN(600, safe.size.height);
    self.panel.frame = CGRectMake(CGRectGetMidX(safe) - width / 2, CGRectGetMidY(safe) - height / 2, width, height);
    self.panel.hidden = !self.expanded;
    self.bubble.hidden = self.expanded;
}

- (void)dragBubble:(UIPanGestureRecognizer *)gesture {
    CGRect safe = [self usableBounds];
    CGPoint delta = [gesture translationInView:self.window.rootViewController.view];
    CGPoint origin = self.bubble.frame.origin;
    CGFloat xRange = MAX(1, safe.size.width - 56), yRange = MAX(1, safe.size.height - 56);
    self.bubbleFraction = CGPointMake(MAX(0, MIN(1, (origin.x + delta.x - safe.origin.x) / xRange)),
                                      MAX(0, MIN(1, (origin.y + delta.y - safe.origin.y) / yRange)));
    [gesture setTranslation:CGPointZero inView:self.window.rootViewController.view];
    [self layoutControls];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [NSUserDefaults.standardUserDefaults setObject:@{@"x": @(self.bubbleFraction.x), @"y": @(self.bubbleFraction.y)}
                                               forKey:@"AppleLive.BubblePosition.v1"];
    }
}

- (void)togglePanel {
    self.expanded = !self.expanded;
    [self layoutControls];
    [self refresh];
}

- (void)restoreKeyWindow {
    [self.previousKeyWindow makeKeyWindow];
    self.previousKeyWindow = nil;
}

- (void)syncConnection {
    NSUInteger mode = [@[@"auto", @"usb", @"lan"] indexOfObject:self.connection[@"mode"]];
    self.connectionControl.selectedSegmentIndex = mode == NSNotFound ? 0 : mode;
    NSString *address = [NSString stringWithFormat:@"%@:%@", self.connection[@"host"], self.connection[@"port"]];
    [self.addressButton setTitle:ALParseComputerAddress(address, NULL, NULL)
        ? [@"电脑 · " stringByAppendingString:address] : @"设置电脑局域网地址" forState:UIControlStateNormal];
    self.addressButton.hidden = [self.connection[@"mode"] isEqual:@"usb"];
}

- (void)connectionChanged {
    self.connection[@"mode"] = @[@"auto", @"usb", @"lan"][self.connectionControl.selectedSegmentIndex];
    if (!ALPublishConnection(self.connection)) { [self editAddress]; return; }
    [self syncConnection];
    self.statusLabel.text = @"正在切换连接…";
}

- (void)editAddress {
    if (self.window.rootViewController.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"电脑局域网地址"
        message:@"填写 OBS 的 AppleLive 面板显示的地址。手机和电脑需连接同一局域网。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        NSString *address = [NSString stringWithFormat:@"%@:%@", self.connection[@"host"], self.connection[@"port"]];
        field.text = ALParseComputerAddress(address, NULL, NULL) ? address : @"";
        field.placeholder = @"例如 192.168.1.45:8765";
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.accessibilityLabel = @"电脑 IPv4 地址和端口";
        [field addTarget:self action:@selector(addressEdited:) forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        self.connection = [ALConnectionSettings() mutableCopy];
        [self syncConnection]; [self restoreKeyWindow];
    }]];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"保存并连接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *host; NSNumber *port;
        if (ALParseComputerAddress(weakAlert.textFields.firstObject.text, &host, &port)) {
            self.connection[@"host"] = host;
            self.connection[@"port"] = port;
            if (!ALPublishConnection(self.connection)) self.statusLabel.text = @"连接设置保存失败";
            [self syncConnection];
        }
        [self restoreKeyWindow];
    }];
    save.enabled = ALParseComputerAddress(alert.textFields.firstObject.text, NULL, NULL);
    [alert addAction:save];
    NSArray *windows = self.window.windowScene.windows;
    if (!windows) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        windows = UIApplication.sharedApplication.windows; // Legacy apps without scenes on iOS 13.
#pragma clang diagnostic pop
    }
    for (UIWindow *window in windows) if (window.isKeyWindow && window != self.window) self.previousKeyWindow = window;
    [self.window makeKeyWindow];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)addressEdited:(UITextField *)field {
    UIAlertController *alert = (UIAlertController *)self.window.rootViewController.presentedViewController;
    if ([alert isKindOfClass:UIAlertController.class]) alert.actions.lastObject.enabled = ALParseComputerAddress(field.text, NULL, NULL);
}

- (void)syncControls {
    self.enabledSwitch.on = [self.controls[@"enabled"] boolValue];
    self.mirrorSwitch.on = [self.controls[@"mirror"] boolValue];
    self.audioSwitch.on = [self.controls[@"audio"] boolValue];
    self.fitControl.selectedSegmentIndex = [self.controls[@"fill"] boolValue] ? 1 : 0;
    self.directionLabel.text = [NSString stringWithFormat:@"画面方向 · %ld°", (long)[self.controls[@"rotation"] integerValue] * 90];
}

- (void)saveControls {
    self.published = ALSaveAndPublishControls(self.controls);
    [self syncControls];
    [self refresh];
}

- (void)controlsChanged:(id)sender {
    self.controls[@"enabled"] = @(self.enabledSwitch.on);
    self.controls[@"mirror"] = @(self.mirrorSwitch.on);
    self.controls[@"audio"] = @(self.audioSwitch.on);
    self.controls[@"fill"] = @(self.fitControl.selectedSegmentIndex == 1);
    [self saveControls];
    (void)sender;
}
- (void)rotateLeft { self.controls[@"rotation"] = @(([self.controls[@"rotation"] integerValue] + 3) % 4); [self saveControls]; }
- (void)rotateRight { self.controls[@"rotation"] = @(([self.controls[@"rotation"] integerValue] + 1) % 4); [self saveControls]; }
- (void)resetControls { self.controls = [ALDefaultControls(NSBundle.mainBundle.bundleIdentifier) mutableCopy]; [self saveControls]; }

- (void)refresh {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        self.window.hidden = YES;
        return;
    }
    if (!self.window) [self buildWindow];
    if (!self.window.rootViewController.presentedViewController) {
        self.connection = [ALConnectionSettings() mutableCopy];
        [self syncConnection];
    }
    self.window.hidden = NO;
    if (!self.published) self.published = ALPublishControls(self.controls);
    NSDictionary *status = ALReadStreamStatus();
    NSString *connection = [status[@"usb"] boolValue] ? @"USB" : @"局域网";
    if (![self.controls[@"enabled"] boolValue]) self.statusLabel.text = @"已关闭 · 使用手机摄像头";
    else if ([status[@"video"] boolValue]) self.statusLabel.text = [connection stringByAppendingString:@" · 已收到电脑画面"];
    else if ([status[@"connected"] boolValue]) self.statusLabel.text = [connection stringByAppendingString:@" · 等待电脑画面"];
    else self.statusLabel.text = @"等待电脑连接";
    self.hintLabel.text = !self.published ? @"设置暂未生效，请重新打开当前 App。" :
        ([self.controls[@"audio"] boolValue] && ![status[@"audio"] boolValue]
            ? @"电脑端尚未发送声音。方向和比例会自动保存。" : @"设置会自动保存，只对当前 App 生效。");
    [self layoutControls];
}
@end
