#import "ALFloatingPanel.h"
#import "ALControls.h"
#import "ALConnection.h"
#import "ALVirtualCamera.h"
#import "ALAudioRing.h"
#import "ALCyberTheme.h"
#import "ALSourceSettings.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kALSourceDefaults = @"AppleLive.Source.v2";
static NSURL *ALMediaDirectory(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"AppleLive/Media" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}
static NSString *ALDefaultStreamURL(void) {
    NSDictionary *connection = ALConnectionSettings();
    NSString *address = [NSString stringWithFormat:@"%@:%@", connection[@"host"], connection[@"port"]];
    return ALParseComputerAddress(address, NULL, NULL)
        ? [NSString stringWithFormat:@"rtmp://%@:1935/live/applelive", connection[@"host"]] : @"";
}

static NSString *ALFriendlyStreamError(NSString *error) {
    NSString *value = error ?: @"";
    if ([value rangeOfString:@"No route to host" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [value rangeOfString:@"Network is unreachable" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return @"电脑不可达：连接同一 Wi-Fi，并在系统设置 → 隐私 → 本地网络中允许当前 App";
    if ([value rangeOfString:@"Connection refused" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return @"电脑未启动接收：请在 OBS 点击“获取推流码”，再点击“开播”";
    if ([value rangeOfString:@"Immediate exit requested" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [value rangeOfString:@"timed out" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return @"连接超时：检查电脑 IP、Wi-Fi 和 Windows 防火墙授权";
    if ([value rangeOfString:@"not found" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [value rangeOfString:@"404" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return @"没有找到这条流：请核对地址末尾 /live/applelive";
    return value.length ? value : @"未知网络错误";
}

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
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (self.onLayout) self.onLayout(); }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface ALFloatingPanel () <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property(nonatomic) ALPassThroughWindow *window;
@property(nonatomic) UIView *panel;
@property(nonatomic) UIButton *bubble;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UILabel *sourceLabel;
@property(nonatomic) UILabel *audioLabel;
@property(nonatomic) UILabel *signalLabel;
@property(nonatomic) UIView *signalDot;
@property(nonatomic) UIButton *albumButton;
@property(nonatomic) UIButton *fileButton;
@property(nonatomic) UIButton *streamButton;
@property(nonatomic) UIButton *usbButton;
@property(nonatomic) UIButton *externalButton;
@property(nonatomic) UIButton *playButton;
@property(nonatomic) UIButton *rotateButton;
@property(nonatomic) UISwitch *enabledSwitch;
@property(nonatomic) UISwitch *mirrorSwitch;
@property(nonatomic) UISwitch *fisheyeSwitch;
@property(nonatomic) UISlider *fisheyeSlider;
@property(nonatomic) UILabel *fisheyeStrengthLabel;
@property(nonatomic) UIStackView *fisheyeStrengthControls;
@property(nonatomic) UISwitch *audioSwitch;
@property(nonatomic) UISegmentedControl *fitControl;
@property(nonatomic) UIStackView *playRow;
@property(nonatomic) NSMutableDictionary *controls;
@property(nonatomic) NSMutableDictionary *source;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL importing;
@property(nonatomic) CGPoint bubbleFraction;
@end

@implementation ALFloatingPanel
+ (void)installForCurrentApplication {
    dispatch_async(dispatch_get_main_queue(), ^{
        static ALFloatingPanel *instance;
        if (instance) return;
        instance = [ALFloatingPanel new];
        instance.controls = [ALLoadAppControls() mutableCopy];
        instance.source = [ALMigrateMediaSource([NSUserDefaults.standardUserDefaults dictionaryForKey:kALSourceDefaults],
            ALDefaultStreamURL()) mutableCopy];
        [NSUserDefaults.standardUserDefaults setObject:instance.source forKey:kALSourceDefaults];
        NSDictionary *position = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"AppleLive.BubblePosition.v1"];
        instance.bubbleFraction = position ? CGPointMake([position[@"x"] doubleValue], [position[@"y"] doubleValue]) : CGPointMake(0, 0.2);
        [NSNotificationCenter.defaultCenter addObserver:instance selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:instance selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSTimer scheduledTimerWithTimeInterval:0.4 target:instance selector:@selector(refresh) userInfo:nil repeats:YES];
        [instance applySource]; [instance refresh];
    });
}
- (ALVirtualCamera *)camera { return ALVirtualCamera.sharedInstance; }
- (UIColor *)accent { return ALCyberRed(); }
- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *label = [UILabel new]; label.text = text; label.textColor = ALCyberText();
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:size weight:UIFontWeightMedium] maximumPointSize:size * 1.5];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}
- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [ALInjectedCyberButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    if (symbol) [button setImage:[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
    button.tintColor = self.accent;
    [button setTitleColor:ALCyberText() forState:UIControlStateNormal];
    button.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] maximumPointSize:19];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    button.accessibilityLabel = title;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UISwitch *)toggle:(NSString *)title {
    UISwitch *toggle = [UISwitch new]; toggle.onTintColor = self.accent; toggle.accessibilityLabel = title;
    toggle.thumbTintColor = ALCyberText();
    [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [toggle addTarget:self action:@selector(controlsChanged:) forControlEvents:UIControlEventValueChanged];
    return toggle;
}
- (UIStackView *)row:(NSArray *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal; row.alignment = UIStackViewAlignmentCenter; row.spacing = 6;
    NSLayoutConstraint *minimumHeight = [row.heightAnchor constraintGreaterThanOrEqualToConstant:38];
    minimumHeight.priority = 999; minimumHeight.active = YES;
    return row;
}
- (UIView *)section:(NSString *)title views:(NSArray<UIView *> *)views {
    ALInjectedCyberSurface *surface = [ALInjectedCyberSurface new];
    UILabel *caption = [self label:title size:10]; caption.textColor = self.accent;
    caption.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:[@[caption] arrayByAddingObjectsFromArray:views]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [surface addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:surface.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-8],
    ]];
    return surface;
}
- (void)buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) { scene = (id)candidate; break; }
    self.window = scene ? [[ALPassThroughWindow alloc] initWithWindowScene:scene] : [[ALPassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.windowLevel = UIWindowLevelAlert + 1;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    ALPanelViewController *root = [ALPanelViewController new]; root.view.backgroundColor = UIColor.clearColor;
    self.window.rootViewController = root;
    __weak typeof(self) weakSelf = self;
    root.onLayout = ^{ [weakSelf layoutControls]; };
    self.bubble = [ALInjectedBubbleButton buttonWithType:UIButtonTypeCustom];
    self.bubble.backgroundColor = UIColor.clearColor; self.bubble.tintColor = self.accent;
    self.bubble.layer.cornerRadius = 28; self.bubble.clipsToBounds = YES;
    [self.bubble setImage:ALCyberMarkImage(CGSizeMake(56, 56)) forState:UIControlStateNormal];
    self.bubble.accessibilityLabel = @"打开 AppleLive 控制面板";
    self.bubble.accessibilityHint = @"双击打开，拖动可移动悬浮按钮";
    [self.bubble addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBubble:)]];
    [root.view addSubview:self.bubble];
    self.panel = [ALInjectedCyberSurface new]; self.panel.backgroundColor = ALCyberBackground();
    self.panel.layer.cornerRadius = 16; self.panel.clipsToBounds = YES;
    [root.view addSubview:self.panel];
    UIImageView *brand = [[UIImageView alloc] initWithImage:ALCyberMarkImage(CGSizeMake(36, 36))];
    [brand.widthAnchor constraintEqualToConstant:36].active = YES;
    [brand.heightAnchor constraintEqualToConstant:36].active = YES;
    UILabel *title = [self label:@"AppleLive" size:21]; title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    UILabel *subtitle = [self label:@"ICE BLUE / ALL SOURCES" size:8];
    subtitle.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightMedium]; subtitle.textColor = self.accent;
    UIStackView *wordmark = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    wordmark.axis = UILayoutConstraintAxisVertical; wordmark.spacing = 2;
    UIButton *close = [self button:@"" symbol:@"xmark" action:@selector(togglePanel)];
    close.accessibilityLabel = @"收起控制面板";
    [close.widthAnchor constraintEqualToConstant:48].active = YES;
    UIStackView *header = [self row:@[brand, wordmark, close]];
    [header.heightAnchor constraintEqualToConstant:40].active = YES;
    self.statusLabel = [self label:@"等待信号" size:18];
    self.sourceLabel = [self label:@"点击检测，填写拉流地址" size:12]; self.sourceLabel.textColor = ALCyberMuted();
    self.signalDot = [UIView new]; self.signalDot.backgroundColor = ALCyberMuted(); self.signalDot.layer.cornerRadius = 3;
    [self.signalDot.widthAnchor constraintEqualToConstant:6].active = YES;
    [self.signalDot.heightAnchor constraintEqualToConstant:6].active = YES;
    self.signalLabel = [self label:@"STANDBY" size:10]; self.signalLabel.textColor = self.accent;
    self.signalLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold];
    self.sourceLabel.numberOfLines = 1;
    self.sourceLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.sourceLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    ALInjectedCyberSurface *signal = (id)[self section:@"LIVE FEED / 信号状态" views:@[
        [self row:@[self.signalDot, self.signalLabel, self.statusLabel, self.sourceLabel]]]];
    signal.illuminated = YES;
    self.albumButton = [self button:@"相册" symbol:@"photo.on.rectangle" action:@selector(pickAlbum)];
    self.fileButton = [self button:@"文件" symbol:@"folder" action:@selector(pickFile)];
    self.streamButton = [self button:@"检测" symbol:@"dot.radiowaves.left.and.right" action:@selector(editStream)];
    ((ALInjectedCyberButton *)self.streamButton).primary = YES;
    self.usbButton = [self button:@"USB 直连" symbol:@"cable.connector" action:@selector(selectUSB)];
    self.externalButton = [self button:@"外接相机（测试）" symbol:@"camera.on.rectangle" action:@selector(selectExternal)];
    UIStackView *files = [self row:@[self.albumButton, self.fileButton]]; files.distribution = UIStackViewDistributionFillEqually;
    UIStackView *inputs = [self row:@[self.streamButton, self.usbButton]]; inputs.distribution = UIStackViewDistributionFillEqually;
    UIView *sourceSection = [self section:@"01 / 信号源" views:@[files, inputs, self.externalButton]];
    // Keep source selection compact; longer picture settings scroll below it.
    [sourceSection.heightAnchor constraintGreaterThanOrEqualToConstant:164].active = YES;
    [sourceSection setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [sourceSection setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    self.enabledSwitch = [self toggle:@"替换画面"];
    self.mirrorSwitch = [self toggle:@"镜像"];
    self.fisheyeSwitch = [self toggle:@"鱼眼效果"];
    self.fisheyeSwitch.accessibilityHint = @"打开后画面呈鱼眼弯曲，关闭恢复原画面";
    self.audioSwitch = [self toggle:@"内录"];
    self.playButton = [self button:@"暂停" symbol:@"pause.fill" action:@selector(togglePlayback)];
    UIButton *restore = [self button:@"恢复手机相机" symbol:@"camera" action:@selector(restoreCamera)];
    self.playRow = [self row:@[self.playButton, restore]]; self.playRow.distribution = UIStackViewDistributionFillEqually;
    self.rotateButton = [self button:@"旋转：0°" symbol:@"rotate.right" action:@selector(rotate)];
    self.fitControl = [[UISegmentedControl alloc] initWithItems:@[@"完整", @"铺满"]];
    [self.fitControl.heightAnchor constraintEqualToConstant:40].active = YES;
    self.fitControl.accessibilityLabel = @"画面比例";
    self.fitControl.backgroundColor = ALCyberBackground();
    self.fitControl.selectedSegmentTintColor = [UIColor colorWithRed:0.84 green:0.93 blue:0.98 alpha:1];
    [self.fitControl setTitleTextAttributes:@{NSForegroundColorAttributeName:ALCyberMuted()} forState:UIControlStateNormal];
    [self.fitControl setTitleTextAttributes:@{NSForegroundColorAttributeName:ALCyberText()} forState:UIControlStateSelected];
    [self.fitControl addTarget:self action:@selector(controlsChanged:) forControlEvents:UIControlEventValueChanged];
    self.audioLabel = [self label:@"" size:10]; self.audioLabel.textColor = ALCyberMuted();
    UIStackView *visualToggleRow = [self row:@[
        [self row:@[[self label:@"替换画面" size:13], self.enabledSwitch]],
        [self row:@[[self label:@"镜像" size:13], self.mirrorSwitch]]]];
    visualToggleRow.distribution = UIStackViewDistributionFillEqually;
    visualToggleRow.spacing = 8;
    UIStackView *formatRow = [self row:@[self.rotateButton, self.fitControl]];
    formatRow.distribution = UIStackViewDistributionFillEqually;
    UIStackView *fisheyeRow = [self row:@[[self label:@"鱼眼效果" size:14], self.fisheyeSwitch]];
    [fisheyeRow.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    self.fisheyeSlider = [UISlider new];
    self.fisheyeSlider.minimumValue = 0; self.fisheyeSlider.maximumValue = 100;
    self.fisheyeSlider.continuous = YES; self.fisheyeSlider.minimumTrackTintColor = self.accent;
    self.fisheyeSlider.accessibilityLabel = @"鱼眼强度";
    self.fisheyeSlider.accessibilityHint = @"向右增加变形，零为原画面";
    [self.fisheyeSlider addTarget:self action:@selector(fisheyeStrengthChanged:) forControlEvents:UIControlEventValueChanged];
    [self.fisheyeSlider addTarget:self action:@selector(finishFisheyeAdjustment) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    NSLayoutConstraint *sliderHeight = [self.fisheyeSlider.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    sliderHeight.priority = 999; sliderHeight.active = YES;
    self.fisheyeStrengthLabel = [self label:@"强度：75%" size:13];
    self.fisheyeStrengthControls = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.fisheyeStrengthLabel, self.fisheyeSlider]];
    self.fisheyeStrengthControls.axis = UILayoutConstraintAxisVertical;
    self.fisheyeStrengthControls.spacing = 2;
    UIView *imageSection = [self section:@"02 / 画面控制 · 全部来源" views:@[
        visualToggleRow, fisheyeRow, self.fisheyeStrengthControls, formatRow]];
    UIView *audioSection = [self section:@"03 / 声音" views:@[
        [self row:@[[self label:@"内录" size:14], self.audioSwitch]], self.audioLabel]];
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, signal,
        sourceSection, imageSection, audioSection,
        [self section:@"04 / 播放" views:@[self.playRow]],
    ]]; content.axis = UILayoutConstraintAxisVertical; content.spacing = 3; content.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    [self.panel addSubview:scroll];
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.panel.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-8],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-16],
    ]];
    [self syncControls]; self.window.hidden = NO; [self layoutControls];
}
- (CGRect)safeBounds {
    UIView *view = self.window.rootViewController.view;
    UIEdgeInsets insets = view.safeAreaInsets;
    insets.top += 8; insets.bottom += 8; insets.left += 8; insets.right += 8;
    return UIEdgeInsetsInsetRect(view.bounds, insets);
}
- (void)layoutControls {
    CGRect safe = [self safeBounds];
    CGFloat width = MIN(364, safe.size.width), height = MIN(700, safe.size.height);
    self.panel.frame = CGRectMake(CGRectGetMidX(safe) - width / 2, CGRectGetMidY(safe) - height / 2, width, height);
    self.bubble.frame = CGRectMake(safe.origin.x + MAX(0, safe.size.width - 56) * self.bubbleFraction.x,
        safe.origin.y + MAX(0, safe.size.height - 56) * self.bubbleFraction.y, 56, 56);
    self.panel.hidden = !self.expanded; self.bubble.hidden = self.expanded;
}
- (void)dragBubble:(UIPanGestureRecognizer *)gesture {
    CGRect safe = [self safeBounds]; CGPoint delta = [gesture translationInView:self.window.rootViewController.view];
    CGPoint origin = self.bubble.frame.origin;
    self.bubbleFraction = CGPointMake(MAX(0, MIN(1, (origin.x + delta.x - safe.origin.x) / MAX(1, safe.size.width - 56))),
        MAX(0, MIN(1, (origin.y + delta.y - safe.origin.y) / MAX(1, safe.size.height - 56))));
    [gesture setTranslation:CGPointZero inView:self.window.rootViewController.view]; [self layoutControls];
    if (gesture.state == UIGestureRecognizerStateEnded)
        [NSUserDefaults.standardUserDefaults setObject:@{@"x": @(self.bubbleFraction.x), @"y": @(self.bubbleFraction.y)} forKey:@"AppleLive.BubblePosition.v1"];
}
- (void)togglePanel { self.expanded = !self.expanded; [self refresh]; }
- (void)present:(UIViewController *)controller {
    if (self.window.rootViewController.presentedViewController) return;
    controller.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    controller.view.tintColor = self.accent;
    NSArray *windows = self.window.windowScene.windows;
    if (!windows) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        windows = UIApplication.sharedApplication.windows;
#pragma clang diagnostic pop
    }
    for (UIWindow *window in windows)
        if (window.isKeyWindow && window != self.window) self.previousKeyWindow = window;
    [self.window makeKeyWindow];
    [self.window.rootViewController presentViewController:controller animated:YES completion:nil];
}
- (void)restoreKey { [self.previousKeyWindow makeKeyWindow]; self.previousKeyWindow = nil; }
- (void)saveSource {
    [NSUserDefaults.standardUserDefaults setObject:self.source forKey:kALSourceDefaults];
    self.controls[@"enabled"] = @YES; [self saveControls]; [self applySource];
}
- (void)selectUSB {
    if ([self.source[@"kind"] isEqualToString:@"usb"] && [self.controls[@"enabled"] boolValue]) {
        [self restoreCamera];
        return;
    }
    self.source[@"kind"] = @"usb";
    [self saveSource];
}
- (void)selectExternal {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"外接 UVC 相机（测试）"
        message:@"相机 → HDMI 采集卡 → OTG → 手机。支持尝试 MJPEG / YUY2 画面；采集卡音频暂不接入。是否能打开取决于采集卡和当前 App 的 USB 权限。"
        preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"连接 / 重试" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self restoreKey]; self.source[@"kind"] = @"external"; [self saveSource];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"连接诊断" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIAlertController *report = [UIAlertController alertControllerWithTitle:@"外接相机连接诊断"
            message:self.camera.externalCameraReport preferredStyle:UIAlertControllerStyleAlert];
        [report addAction:[UIAlertAction actionWithTitle:@"复制诊断" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            UIPasteboard.generalPasteboard.string = self.camera.externalCameraReport; [self restoreKey];
        }]];
        [report addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [self restoreKey]; }]];
        [self.window.rootViewController dismissViewControllerAnimated:YES completion:^{
            [self restoreKey]; [self present:report];
        }];
    }]];
    if ([self.source[@"kind"] isEqualToString:@"external"] && [self.controls[@"enabled"] boolValue])
        [menu addAction:[UIAlertAction actionWithTitle:@"断开外接相机" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self restoreKey]; [self restoreCamera];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [self restoreKey]; }]];
    [self present:menu];
}
- (void)applySource {
    if (![self.controls[@"enabled"] boolValue]) { [self.camera selectSource:@"none" URL:nil]; return; }
    NSString *kind = self.source[@"kind"];
    NSURL *url = [kind isEqualToString:@"local"] ? [ALMediaDirectory() URLByAppendingPathComponent:self.source[@"file"] ?: @""]
        : [kind isEqualToString:@"network"] ? [NSURL URLWithString:self.source[@"url"] ?: @""] : nil;
    if ([kind isEqualToString:@"network"] && !ALValidStreamURL(self.source[@"url"])) {
        [self.camera selectSource:@"none" URL:nil]; return;
    }
    [self.camera selectSource:kind ?: @"none" URL:url];
}
- (void)syncControls {
    self.enabledSwitch.on = [self.controls[@"enabled"] boolValue]; self.mirrorSwitch.on = [self.controls[@"mirror"] boolValue];
    self.audioSwitch.on = [self.controls[@"audio"] boolValue];
    self.fisheyeSwitch.on = [self.controls[@"fisheye"] boolValue];
    [self syncFisheyeStrength];
    self.fitControl.selectedSegmentIndex = [self.controls[@"fill"] boolValue] ? 1 : 0;
    NSString *rotation = [NSString stringWithFormat:@"旋转：%ld°", (long)[self.controls[@"rotation"] integerValue] * 90];
    [self.rotateButton setTitle:rotation forState:UIControlStateNormal];
}
- (void)syncFisheyeStrength {
    NSUInteger strength = ALFisheyeStrength(self.controls);
    self.fisheyeSlider.value = strength;
    self.fisheyeStrengthLabel.text = [NSString stringWithFormat:@"强度：%lu%%", (unsigned long)strength];
    self.fisheyeSlider.accessibilityValue = [NSString stringWithFormat:@"%lu%%", (unsigned long)strength];
    self.fisheyeStrengthControls.hidden = ![self.controls[@"fisheye"] boolValue];
}
- (void)fisheyeStrengthChanged:(UISlider *)slider {
    self.controls[@"fisheyeStrength"] = @(slider.value);
    self.controls[@"fisheyeStrength"] = @(ALFisheyeStrength(self.controls));
    [self syncFisheyeStrength];
    ALPublishControls(self.controls);
    // Publish every value to the next video frame; debounce disk writes. The
    // delayed save also handles VoiceOver adjustments without a touch-up event.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveControls) object:nil];
    [self performSelector:@selector(saveControls) withObject:nil afterDelay:0.25];
}
- (void)finishFisheyeAdjustment { [self saveControls]; }
- (void)saveControls {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveControls) object:nil];
    self.controls[@"muted"] = @NO; ALSaveAndPublishControls(self.controls); [self syncControls];
}
- (void)controlsChanged:(id)sender {
    BOOL previous = [self.controls[@"enabled"] boolValue];
    self.controls[@"enabled"] = @(self.enabledSwitch.on); self.controls[@"mirror"] = @(self.mirrorSwitch.on);
    self.controls[@"audio"] = @(self.audioSwitch.on); self.controls[@"muted"] = @NO;
    self.controls[@"fisheye"] = @(self.fisheyeSwitch.on);
    self.controls[@"fill"] = @(self.fitControl.selectedSegmentIndex == 1);
    [self saveControls];
    if (previous != self.enabledSwitch.on) [self applySource];
    if (sender == self.audioSwitch) [self.camera.audioRing clear];
    [self refresh];
}
- (void)rotate { self.controls[@"rotation"] = @(([self.controls[@"rotation"] integerValue] + 1) % 4); [self saveControls]; }
- (void)restoreCamera { self.controls[@"enabled"] = @NO; [self saveControls]; [self.camera selectSource:@"none" URL:nil]; [self refresh]; }
- (void)togglePlayback {
    BOOL paused = [self.camera.mediaStatus[@"state"] isEqualToString:@"paused"];
    if ([self.camera.mediaStatus[@"state"] isEqualToString:@"ended"]) [self applySource];
    else [self.camera setMediaPaused:!paused];
    [self refresh];
}
- (void)editStream {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测 · 网络信号" message:@"粘贴完整 RTMP 或 RTSP 地址。此模式要求手机与推流电脑连接同一 Wi-Fi。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [self.source[@"url"] length] ? self.source[@"url"] : ALDefaultStreamURL();
        field.placeholder = @"rtmp://电脑IP:1935/live/applelive";
        field.textColor = ALCyberText(); field.tintColor = self.accent;
        field.backgroundColor = ALCyberBackground();
        field.keyboardType = UIKeyboardTypeURL; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.accessibilityLabel = @"拉流地址";
        [field addTarget:self action:@selector(validateStream:) forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(id action) { [self restoreKey]; }]];
    if ([self.source[@"kind"] isEqualToString:@"network"])
        [alert addAction:[UIAlertAction actionWithTitle:@"停止拉流" style:UIAlertActionStyleDestructive handler:^(id action) { [self restoreCamera]; [self restoreKey]; }]];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *play = [UIAlertAction actionWithTitle:@"开始拉流" style:UIAlertActionStyleDefault handler:^(id action) {
        NSString *value = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ALValidStreamURL(value)) { self.source[@"kind"] = @"network"; self.source[@"url"] = value; [self saveSource]; }
        [self restoreKey];
    }]; play.enabled = ALValidStreamURL(alert.textFields.firstObject.text); [alert addAction:play]; [self present:alert];
}
- (void)validateStream:(UITextField *)field {
    UIAlertController *alert = (id)self.window.rootViewController.presentedViewController;
    alert.actions.lastObject.enabled = ALValidStreamURL([field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
}
- (void)pickAlbum {
    if (self.importing) return;
    PHPickerConfiguration *configuration = [PHPickerConfiguration new];
    configuration.selectionLimit = 1;
    configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration]; picker.delegate = self;
    [self present:picker];
}
- (void)pickFile {
    if (self.importing) return;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage, UTTypeMovie] asCopy:YES];
    picker.delegate = self; picker.allowsMultipleSelection = NO; [self present:picker];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{ [self restoreKey]; }];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider) return;
    NSString *type = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier] ? UTTypeMovie.identifier : UTTypeImage.identifier;
    self.importing = YES;
    [provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
        // The provider's temporary URL is valid only inside this callback.
        [self importFile:url error:error];
    }];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self restoreKey]; self.importing = YES;
    NSURL *url = urls.firstObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self importFile:url error:nil]; });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self restoreKey]; }
- (void)importFile:(NSURL *)url error:(NSError *)error {
    BOOL access = [url startAccessingSecurityScopedResource];
    NSString *filename = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:url.pathExtension.length ? url.pathExtension : @"media"];
    NSURL *destination = [ALMediaDirectory() URLByAppendingPathComponent:filename];
    if (!error && url) [NSFileManager.defaultManager copyItemAtURL:url toURL:destination error:&error];
    if (access) [url stopAccessingSecurityScopedResource];
    if (!url && !error) error = [NSError errorWithDomain:@"AppleLive" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法读取素材"}];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.importing = NO;
        if (error) {
            self.statusLabel.text = error.localizedDescription;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(id action) { [self restoreKey]; }]]; [self present:alert];
            return;
        }
        NSString *oldFile = self.source[@"file"];
        self.source[@"kind"] = @"local"; self.source[@"file"] = filename; self.source[@"name"] = url.lastPathComponent;
        [self saveSource];
        if (oldFile.length && ![oldFile isEqualToString:filename]) [NSFileManager.defaultManager removeItemAtURL:[ALMediaDirectory() URLByAppendingPathComponent:oldFile] error:nil];
    });
}
- (void)background { self.window.hidden = YES; [self restoreKey]; [self.camera selectSource:@"none" URL:nil]; }
- (void)refresh {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { self.window.hidden = YES; return; }
    if (!self.window) [self buildWindow];
    if (self.window.hidden) [self applySource];
    self.window.hidden = NO;
    NSDictionary *status = self.camera.streamStatus, *media = self.camera.mediaStatus;
    NSString *kind = self.source[@"kind"], *state = media[@"state"];
    BOOL local = [kind isEqualToString:@"local"];
    BOOL network = [kind isEqualToString:@"network"];
    BOOL usb = [kind isEqualToString:@"usb"];
    BOOL external = [kind isEqualToString:@"external"];
    BOOL enabled = [self.controls[@"enabled"] boolValue], video = enabled && [status[@"video"] boolValue];
    BOOL emptyStream = network && !ALValidStreamURL(self.source[@"url"]);
    self.sourceLabel.text = local ? self.source[@"name"] ?: @"本地素材"
        : external ? media[@"device"] ?: @"手机外接 UVC 相机"
        : usb ? @"USB 数据线直连"
        : emptyStream ? @"点击「检测」填写 RTMP / RTSP 地址" : self.source[@"url"];
    self.sourceLabel.numberOfLines = 1; self.sourceLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (self.importing) self.statusLabel.text = @"正在导入…";
    else if (![self.controls[@"enabled"] boolValue]) self.statusLabel.text = @"使用手机摄像头";
    else if (external) self.statusLabel.text = media[@"message"] ?: @"正在识别外接相机…";
    else if (emptyStream) self.statusLabel.text = @"等待添加信号";
    else if (usb && ![status[@"connected"] boolValue]) self.statusLabel.text = @"等待电脑 USB 连接";
    else if (usb && !video) self.statusLabel.text = @"USB 已连接 · 等待 OBS 画面";
    else if ([state isEqualToString:@"error"]) {
        self.statusLabel.text = ALFriendlyStreamError(media[@"error"]);
    }
    else if ([state isEqualToString:@"paused"]) self.statusLabel.text = @"已暂停";
    else if ([state isEqualToString:@"ended"]) self.statusLabel.text = @"播放结束";
    else self.statusLabel.text = [status[@"video"] boolValue] ? (local ? @"素材播放中" : usb ? @"USB 直连中" : @"拉流成功") : @"正在读取…";
    self.signalLabel.text = !enabled ? @"CAMERA" : [state isEqualToString:@"error"] ? @"OFFLINE"
        : [state isEqualToString:@"paused"] ? @"PAUSED" : video ? @"LIVE" : @"STANDBY";
    self.signalDot.backgroundColor = video ? self.accent : ALCyberMuted();
    self.streamButton.selected = enabled && !emptyStream && [kind isEqualToString:@"network"];
    self.usbButton.selected = enabled && usb;
    self.externalButton.selected = enabled && external;
    [self.usbButton setTitle:enabled && usb ? @"断开 USB" : @"USB 直连" forState:UIControlStateNormal];
    self.usbButton.accessibilityLabel = enabled && usb ? @"断开 USB" : @"USB 直连";
    BOOL seekable = local && [media[@"duration"] doubleValue] > 0;
    self.playButton.hidden = !seekable;
    [self.playButton setTitle:[state isEqualToString:@"paused"] || [state isEqualToString:@"ended"] ? @"播放" : @"暂停" forState:UIControlStateNormal];
    [self.playButton setImage:[UIImage systemImageNamed:([state isEqualToString:@"paused"] || [state isEqualToString:@"ended"]) ? @"play.fill" : @"pause.fill"] forState:UIControlStateNormal];
    self.playButton.accessibilityLabel = [self.playButton titleForState:UIControlStateNormal];
    self.audioLabel.hidden = ![self.controls[@"audio"] boolValue];
    self.audioLabel.text = [status[@"audio"] boolValue] ? @"内录中 · 手机麦克风已关闭" : @"等待源音频 · 手机麦克风已关闭";
    if (external) self.audioLabel.text = @"外接相机暂仅采集画面 · 手机麦克风已关闭";
    [self layoutControls];
}
@end
