#import "ALFloatingPanel.h"
#import "ALControls.h"
#import "ALConnection.h"
#import "ALVirtualCamera.h"
#import "ALAudioRing.h"
#import "ALPreview.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kALSourceDefaults = @"AppleLive.Source.v2";
static NSURL *ALMediaDirectory(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"AppleLive/Media" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}
static BOOL ALValidStreamURL(NSString *value) {
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    return [@[@"rtmp", @"rtmps", @"rtsp", @"http", @"https"] containsObject:url.scheme.lowercaseString] && url.host.length > 0;
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
@property(nonatomic) UILabel *timeLabel;
@property(nonatomic) UILabel *audioLabel;
@property(nonatomic) UIButton *connectButton;
@property(nonatomic) UIButton *addressButton;
@property(nonatomic) UIButton *playButton;
@property(nonatomic) UIButton *rotateButton;
@property(nonatomic) UISwitch *enabledSwitch;
@property(nonatomic) UISwitch *mirrorSwitch;
@property(nonatomic) UISwitch *audioSwitch;
@property(nonatomic) UISwitch *muteSwitch;
@property(nonatomic) UISwitch *loopSwitch;
@property(nonatomic) UISegmentedControl *fitControl;
@property(nonatomic) UISlider *timeline;
@property(nonatomic) UIStackView *playRow;
@property(nonatomic) UIStackView *loopRow;
@property(nonatomic) NSMutableDictionary *controls;
@property(nonatomic) NSMutableDictionary *source;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, weak) UILabel *previewStatus;
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
        instance.source = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kALSourceDefaults] mutableCopy]
            ?: [@{@"kind": @"computer", @"loop": @YES} mutableCopy];
        NSDictionary *position = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"AppleLive.BubblePosition.v1"];
        instance.bubbleFraction = position ? CGPointMake([position[@"x"] doubleValue], [position[@"y"] doubleValue]) : CGPointMake(0, 0.2);
        [NSNotificationCenter.defaultCenter addObserver:instance selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:instance selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSTimer scheduledTimerWithTimeInterval:0.4 target:instance selector:@selector(refresh) userInfo:nil repeats:YES];
        [instance applySource]; [instance refresh];
    });
}
- (ALVirtualCamera *)camera { return ALVirtualCamera.sharedInstance; }
- (UIColor *)accent { return [UIColor colorWithRed:0.12 green:0.55 blue:0.42 alpha:1]; }
- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *label = [UILabel new]; label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    label.textColor = UIColor.labelColor;
    label.numberOfLines = 0;
    return label;
}
- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    if (symbol) [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = self.accent;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    button.layer.cornerRadius = 8;
    button.backgroundColor = UIColor.tertiarySystemFillColor;
    button.accessibilityLabel = title;
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UISwitch *)toggle:(NSString *)title {
    UISwitch *toggle = [UISwitch new]; toggle.onTintColor = self.accent; toggle.accessibilityLabel = title;
    [toggle addTarget:self action:@selector(controlsChanged:) forControlEvents:UIControlEventValueChanged];
    return toggle;
}
- (UIStackView *)row:(NSArray *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal; row.alignment = UIStackViewAlignmentCenter; row.spacing = 8;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return row;
}
- (void)buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) { scene = (id)candidate; break; }
    self.window = scene ? [[ALPassThroughWindow alloc] initWithWindowScene:scene] : [[ALPassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.windowLevel = UIWindowLevelAlert + 1;
    self.window.backgroundColor = UIColor.clearColor;
    ALPanelViewController *root = [ALPanelViewController new]; root.view.backgroundColor = UIColor.clearColor;
    self.window.rootViewController = root;
    __weak typeof(self) weakSelf = self;
    root.onLayout = ^{ [weakSelf layoutControls]; };
    self.bubble = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bubble.backgroundColor = self.accent; self.bubble.tintColor = UIColor.whiteColor; self.bubble.layer.cornerRadius = 28;
    [self.bubble setImage:[UIImage systemImageNamed:@"video.fill"] forState:UIControlStateNormal];
    self.bubble.accessibilityLabel = @"AppleLive";
    [self.bubble addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBubble:)]];
    [root.view addSubview:self.bubble];
    self.panel = [UIView new]; self.panel.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.panel.layer.cornerRadius = 8; self.panel.clipsToBounds = YES;
    [root.view addSubview:self.panel];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panel addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.panel.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor],
    ]];
    UILabel *title = [self label:@"AppleLive" size:20];
    UIButton *close = [self button:@"收起" symbol:@"xmark" action:@selector(togglePanel)];
    [close.widthAnchor constraintEqualToConstant:66].active = YES;
    self.statusLabel = [self label:@"等待画面" size:13]; self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.sourceLabel = [self label:@"当前：电脑" size:14];
    UIStackView *sources = [self row:@[
        [self button:@"相册" symbol:@"photo.on.rectangle" action:@selector(pickAlbum)],
        [self button:@"文件" symbol:@"folder" action:@selector(pickFile)],
        [self button:@"检测" symbol:@"network" action:@selector(editStream)],
    ]]; sources.distribution = UIStackViewDistributionFillEqually;
    self.connectButton = [self button:@"连接电脑" symbol:@"desktopcomputer" action:@selector(toggleComputer)];
    self.addressButton = [self button:@"电脑地址" symbol:@"link" action:@selector(editComputer)];
    UIStackView *computer = [self row:@[self.connectButton, self.addressButton]]; computer.distribution = UIStackViewDistributionFillEqually;
    self.enabledSwitch = [self toggle:@"替换画面"];
    self.mirrorSwitch = [self toggle:@"镜像"];
    self.audioSwitch = [self toggle:@"内录"];
    self.muteSwitch = [self toggle:@"静音"];
    self.loopSwitch = [self toggle:@"循环"];
    self.playButton = [self button:@"暂停" symbol:@"pause.fill" action:@selector(togglePlayback)];
    UIButton *preview = [self button:@"预览" symbol:@"eye" action:@selector(showPreview)];
    self.playRow = [self row:@[self.playButton, preview]]; self.playRow.distribution = UIStackViewDistributionFillEqually;
    self.loopRow = [self row:@[[self label:@"循环播放" size:15], self.loopSwitch]];
    self.timeline = [UISlider new]; self.timeline.accessibilityLabel = @"播放进度"; self.timeline.tintColor = self.accent;
    [self.timeline.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.timeline addTarget:self action:@selector(seek:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    self.timeLabel = [self label:@"00:00 / 00:00" size:12]; self.timeLabel.textAlignment = NSTextAlignmentRight;
    self.rotateButton = [self button:@"旋转：0°" symbol:@"rotate.right" action:@selector(rotate)];
    self.fitControl = [[UISegmentedControl alloc] initWithItems:@[@"完整", @"铺满"]];
    [self.fitControl.heightAnchor constraintEqualToConstant:44].active = YES;
    self.fitControl.accessibilityLabel = @"画面比例";
    [self.fitControl addTarget:self action:@selector(controlsChanged:) forControlEvents:UIControlEventValueChanged];
    self.audioLabel = [self label:@"" size:12]; self.audioLabel.textColor = UIColor.secondaryLabelColor;
    UIButton *restore = [self button:@"恢复相机" symbol:@"camera" action:@selector(restoreCamera)]; restore.tintColor = UIColor.systemRedColor;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self row:@[title, close]], self.statusLabel, self.sourceLabel, sources, computer,
        [self row:@[[self label:@"替换画面" size:15], self.enabledSwitch]],
        [self row:@[[self label:@"镜像" size:15], self.mirrorSwitch]],
        [self row:@[[self label:@"内录" size:15], self.audioSwitch]],
        [self row:@[[self label:@"静音" size:15], self.muteSwitch]], self.audioLabel,
        self.rotateButton, self.fitControl, self.playRow, self.loopRow, self.timeline, self.timeLabel, restore,
    ]]; content.axis = UILayoutConstraintAxisVertical; content.spacing = 8; content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
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
    CGFloat width = MIN(336, safe.size.width), height = MIN(620, safe.size.height);
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
    for (UIWindow *window in self.window.windowScene.windows)
        if (window.isKeyWindow && window != self.window) self.previousKeyWindow = window;
    [self.window makeKeyWindow];
    [self.window.rootViewController presentViewController:controller animated:YES completion:nil];
}
- (void)restoreKey { [self.previousKeyWindow makeKeyWindow]; self.previousKeyWindow = nil; }
- (void)saveSource {
    [NSUserDefaults.standardUserDefaults setObject:self.source forKey:kALSourceDefaults];
    self.controls[@"enabled"] = @YES; [self saveControls]; [self applySource];
}
- (void)applySource {
    [self.camera setMediaLoop:[self.source[@"loop"] boolValue]];
    if (![self.controls[@"enabled"] boolValue]) { [self.camera selectSource:@"none" URL:nil]; return; }
    NSString *kind = self.source[@"kind"];
    NSURL *url = [kind isEqualToString:@"local"] ? [ALMediaDirectory() URLByAppendingPathComponent:self.source[@"file"] ?: @""]
        : [kind isEqualToString:@"network"] ? [NSURL URLWithString:self.source[@"url"] ?: @""] : nil;
    [self.camera selectSource:kind ?: @"computer" URL:url];
}
- (void)syncControls {
    self.enabledSwitch.on = [self.controls[@"enabled"] boolValue]; self.mirrorSwitch.on = [self.controls[@"mirror"] boolValue];
    self.audioSwitch.on = [self.controls[@"audio"] boolValue]; self.muteSwitch.on = [self.controls[@"muted"] boolValue];
    self.loopSwitch.on = [self.source[@"loop"] boolValue];
    self.fitControl.selectedSegmentIndex = [self.controls[@"fill"] boolValue] ? 1 : 0;
    NSString *rotation = [NSString stringWithFormat:@"旋转：%ld°", (long)[self.controls[@"rotation"] integerValue] * 90];
    [self.rotateButton setTitle:rotation forState:UIControlStateNormal];
}
- (void)saveControls { ALSaveAndPublishControls(self.controls); [self syncControls]; }
- (void)controlsChanged:(id)sender {
    BOOL previous = [self.controls[@"enabled"] boolValue];
    self.controls[@"enabled"] = @(self.enabledSwitch.on); self.controls[@"mirror"] = @(self.mirrorSwitch.on);
    self.controls[@"audio"] = @(self.audioSwitch.on); self.controls[@"muted"] = @(self.muteSwitch.on);
    self.controls[@"fill"] = @(self.fitControl.selectedSegmentIndex == 1); self.source[@"loop"] = @(self.loopSwitch.on);
    [self.camera setMediaLoop:self.loopSwitch.on];
    [NSUserDefaults.standardUserDefaults setObject:self.source forKey:kALSourceDefaults]; [self saveControls];
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
- (void)seek:(UISlider *)slider { [self.camera seekMedia:slider.value]; }
- (void)toggleComputer {
    NSDictionary *status = self.camera.streamStatus;
    NSMutableDictionary *connection = [ALConnectionSettings() mutableCopy];
    BOOL current = [self.source[@"kind"] isEqualToString:@"computer"] && [self.controls[@"enabled"] boolValue];
    connection[@"paused"] = @(current && [status[@"connected"] boolValue] && ![connection[@"paused"] boolValue]);
    ALPublishConnection(connection);
    self.source[@"kind"] = @"computer"; [self saveSource]; [self refresh];
}
- (void)editComputer {
    NSDictionary *connection = ALConnectionSettings();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"电脑地址" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [NSString stringWithFormat:@"%@:%@", connection[@"host"], connection[@"port"]];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.accessibilityLabel = @"电脑地址";
        [field addTarget:self action:@selector(validateComputer:) forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(id action) { [self restoreKey]; }]];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"连接" style:UIAlertActionStyleDefault handler:^(id action) {
        NSString *host; NSNumber *port;
        if (ALParseComputerAddress(weakAlert.textFields.firstObject.text, &host, &port)) {
            ALPublishConnection(@{@"mode": @"auto", @"host": host, @"port": port, @"paused": @NO});
            self.source[@"kind"] = @"computer"; [self saveSource];
        }
        [self restoreKey];
    }]; save.enabled = ALParseComputerAddress(alert.textFields.firstObject.text, NULL, NULL); [alert addAction:save]; [self present:alert];
}
- (void)validateComputer:(UITextField *)field {
    UIAlertController *alert = (id)self.window.rootViewController.presentedViewController;
    alert.actions.lastObject.enabled = ALParseComputerAddress(field.text, NULL, NULL);
}
- (void)editStream {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"拉流地址" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.source[@"url"] ?: @"";
        field.placeholder = @"rtmp://电脑IP/live/流名称";
        field.keyboardType = UIKeyboardTypeURL; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.accessibilityLabel = @"拉流地址";
        [field addTarget:self action:@selector(validateStream:) forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(id action) { [self restoreKey]; }]];
    if ([self.source[@"kind"] isEqualToString:@"network"])
        [alert addAction:[UIAlertAction actionWithTitle:@"停止拉流" style:UIAlertActionStyleDestructive handler:^(id action) { [self restoreCamera]; [self restoreKey]; }]];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *play = [UIAlertAction actionWithTitle:@"拉流" style:UIAlertActionStyleDefault handler:^(id action) {
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
- (void)showPreview {
    UIViewController *controller = [UIViewController new]; controller.view.backgroundColor = UIColor.systemBackgroundColor;
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
    ALPreviewView *preview = [ALPreviewView new]; preview.translatesAutoresizingMaskIntoConstraints = NO; [controller.view addSubview:preview];
    UIButton *close = [self button:@"关闭" symbol:@"xmark" action:@selector(closePreview)]; close.translatesAutoresizingMaskIntoConstraints = NO; [controller.view addSubview:close];
    UILabel *status = [self label:self.statusLabel.text size:14]; status.translatesAutoresizingMaskIntoConstraints = NO; self.previewStatus = status; [controller.view addSubview:status];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [close.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16], [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [close.widthAnchor constraintEqualToConstant:72], [status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [status.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8], [status.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
        [preview.topAnchor constraintEqualToAnchor:close.bottomAnchor constant:8], [preview.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [preview.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [preview.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    ]]; [self present:controller];
}
- (void)closePreview { [self.window.rootViewController dismissViewControllerAnimated:YES completion:^{ [self restoreKey]; }]; }
- (void)background { self.window.hidden = YES; [self restoreKey]; [self.camera selectSource:@"none" URL:nil]; }
- (void)refresh {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { self.window.hidden = YES; return; }
    if (!self.window) [self buildWindow];
    if (self.window.hidden) [self applySource];
    self.window.hidden = NO;
    NSDictionary *status = self.camera.streamStatus, *media = self.camera.mediaStatus;
    NSString *kind = self.source[@"kind"], *state = media[@"state"];
    BOOL local = [kind isEqualToString:@"local"], computer = [kind isEqualToString:@"computer"];
    NSString *transport = [status[@"usb"] boolValue] ? @"USB" : @"局域网";
    self.sourceLabel.text = [NSString stringWithFormat:@"当前：%@", computer ? @"电脑" : local ? self.source[@"name"] ?: @"素材" : @"网络拉流"];
    if (self.importing) self.statusLabel.text = @"正在导入…";
    else if (![self.controls[@"enabled"] boolValue]) self.statusLabel.text = @"使用手机摄像头";
    else if (computer) self.statusLabel.text = [status[@"video"] boolValue] ? [transport stringByAppendingString:@" · 已收到画面"] : [ALConnectionSettings()[@"paused"] boolValue] ? @"已断开" : @"等待电脑连接";
    else if ([state isEqualToString:@"error"]) self.statusLabel.text = [@"读取失败：" stringByAppendingString:media[@"error"] ?: @""];
    else if ([state isEqualToString:@"paused"]) self.statusLabel.text = @"已暂停";
    else if ([state isEqualToString:@"ended"]) self.statusLabel.text = @"播放结束";
    else self.statusLabel.text = [status[@"video"] boolValue] ? (local ? @"素材播放中" : @"拉流成功") : @"正在读取…";
    BOOL activeComputer = computer && [status[@"connected"] boolValue] && [self.controls[@"enabled"] boolValue];
    [self.connectButton setTitle:activeComputer ? @"断开电脑" : @"连接电脑" forState:UIControlStateNormal];
    self.addressButton.hidden = activeComputer && [status[@"usb"] boolValue];
    BOOL seekable = local && [media[@"duration"] doubleValue] > 0;
    self.playButton.hidden = !seekable; self.loopRow.hidden = !seekable;
    self.timeline.hidden = self.timeLabel.hidden = !seekable;
    [self.playButton setTitle:[state isEqualToString:@"paused"] || [state isEqualToString:@"ended"] ? @"播放" : @"暂停" forState:UIControlStateNormal];
    [self.playButton setImage:[UIImage systemImageNamed:[state isEqualToString:@"paused"] ? @"play.fill" : @"pause.fill"] forState:UIControlStateNormal];
    self.timeline.maximumValue = MAX(1, [media[@"duration"] floatValue]);
    if (!self.timeline.isTracking) self.timeline.value = [media[@"position"] floatValue];
    int position = [media[@"position"] intValue], duration = [media[@"duration"] intValue];
    self.timeLabel.text = [NSString stringWithFormat:@"%02d:%02d / %02d:%02d", position / 60, position % 60, duration / 60, duration % 60];
    self.audioLabel.hidden = ![self.controls[@"audio"] boolValue];
    self.audioLabel.text = [self.controls[@"muted"] boolValue] ? @"已静音 · 手机麦克风已关闭" : [status[@"audio"] boolValue] ? @"内录中 · 手机麦克风已关闭" : @"等待源音频 · 手机麦克风已关闭";
    self.previewStatus.text = self.statusLabel.text; [self layoutControls];
}
@end
