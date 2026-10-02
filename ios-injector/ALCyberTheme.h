#import <UIKit/UIKit.h>

UIColor *ALCyberBackground(void);
UIColor *ALCyberSurfaceColor(void);
UIColor *ALCyberRed(void);
UIColor *ALCyberText(void);
UIColor *ALCyberMuted(void);
UIImage *ALCyberMarkImage(CGSize size);

@interface ALInjectedCyberSurface : UIView
@property(nonatomic) BOOL illuminated;
@end

@interface ALInjectedCyberButton : UIButton
@property(nonatomic) BOOL primary;
@end

@interface ALInjectedBubbleButton : UIButton
@end
