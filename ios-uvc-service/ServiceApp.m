#import <UIKit/UIKit.h>
#include <signal.h>
#include <errno.h>

static NSString *const stateDirectory=@"/var/mobile/Library/AppleLiveUVC";
@interface ALUVCSetupController : UIViewController
@property(nonatomic) UILabel *statusLabel;
@end
@implementation ALUVCSetupController
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.title=@"AppleLive USB";
    UILabel *title=[UILabel new];title.text=@"手机外接相机";title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    UILabel *instructions=[UILabel new];instructions.numberOfLines=0;
    instructions.text=@"首次使用：复制连接码，打开抖音的 AppleLive 悬浮窗，在“外接相机 → 配对采集服务”中粘贴。以后会记住配对。\n\n相机 → HDMI → UVC 采集卡 → 带供电 OTG → 手机。\n\n连接和断开都在悬浮窗操作。关闭这个工具后，采集服务仍可使用；没有连接时不采集画面。";
    instructions.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel=[UILabel new];self.statusLabel.numberOfLines=0;self.statusLabel.textColor=UIColor.secondaryLabelColor;
    UIButton *copy=[UIButton buttonWithType:UIButtonTypeSystem];[copy setTitle:@"复制连接码" forState:UIControlStateNormal];
    copy.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [copy.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;
    [copy addTarget:self action:@selector(copyCode) forControlEvents:UIControlEventTouchUpInside];
    UIButton *refresh=[UIButton buttonWithType:UIButtonTypeSystem];[refresh setTitle:@"刷新服务状态" forState:UIControlStateNormal];
    [refresh.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [refresh addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
    UIButton *export=[UIButton buttonWithType:UIButtonTypeSystem];[export setTitle:@"导出配套手机插件" forState:UIControlStateNormal];
    [export.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [export addTarget:self action:@selector(exportPlugin:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.statusLabel,instructions,copy,refresh,export]];
    stack.axis=UILayoutConstraintAxisVertical;stack.spacing=24;stack.translatesAutoresizingMaskIntoConstraints=NO;
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:scroll];[scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]]];
    for (UILabel *label in @[title,instructions,self.statusLabel]) label.adjustsFontForContentSizeCategory=YES;
    [self refresh];
}
- (NSString *)token {
    NSString *value=[NSString stringWithContentsOfFile:[stateDirectory stringByAppendingPathComponent:@"connection-token"] encoding:NSASCIIStringEncoding error:nil];
    return value.length==64?value:nil;
}
- (void)refresh {
    NSString *pidText=[NSString stringWithContentsOfFile:[stateDirectory stringByAppendingPathComponent:@"service-pid"] encoding:NSASCIIStringEncoding error:nil];
    int pid=pidText.intValue;
    BOOL alive=pid>1 && (kill(pid,0)==0 || errno==EPERM);
    self.statusLabel.text=alive && self.token?@"采集服务已启动 · 等待悬浮窗连接":@"采集服务尚未启动。请确认 Dopamine 显示已越狱，稍后刷新；持续未启动时重新安装服务包。";
}
- (void)copyCode {
    NSString *token=self.token;
    if (!token) { [self refresh];return; }
    UIPasteboard.generalPasteboard.string=token;
    self.statusLabel.text=@"连接码已复制。回到抖音 → AppleLive → 外接相机 → 配对采集服务。";
}
- (void)exportPlugin:(UIButton *)sender {
    NSURL *url=[NSURL fileURLWithPath:@"/var/jb/Library/AppleLive/AppleLive.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) { self.statusLabel.text=@"配套插件文件缺失，请重新安装服务包。";return; }
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView=sender;share.popoverPresentationController.sourceRect=sender.bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end
@interface ALUVCSetupApp : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation ALUVCSetupApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[ALUVCSetupController new]];
    [self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ALUVCSetupApp.class)); } }
