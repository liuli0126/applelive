#import "ALCyberTheme.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static UIColor *ALHex(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
        green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}
UIColor *ALCyberBackground(void) { return ALHex(0xF2F7FB); }
UIColor *ALCyberSurfaceColor(void) { return ALHex(0xFFFFFF); }
UIColor *ALCyberRed(void) { return ALHex(0x4B9FD1); }
UIColor *ALCyberText(void) { return ALHex(0x17324A); }
UIColor *ALCyberMuted(void) { return ALHex(0x6E8495); }

static UIBezierPath *ALCutPanel(CGRect r, CGFloat cut) {
    (void)cut;
    return [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:14];
}

UIImage *ALCyberMarkImage(CGSize size) {
    CGFloat d = MAX(24, MIN(size.width, size.height));
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(d, d), NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(d / 2, d / 2);
    [ALCyberBackground() setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, d - 2, d - 2)] fill];
    [ALHex(0xA8C9DF) setStroke];
    UIBezierPath *rim = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, d - 4, d - 4)];
    rim.lineWidth = 1; [rim stroke];
    [ALCyberRed() setStroke];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat start = -M_PI_2 + i * 2 * M_PI / 3;
        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:center radius:d / 2 - 2
            startAngle:start endAngle:start + M_PI / 3 clockwise:YES];
        arc.lineWidth = MAX(1.5, d * 0.035); [arc stroke];
    }
    UIBezierPath *star = [UIBezierPath bezierPath];
    for (NSInteger i = 0; i < 10; i++) {
        CGFloat a = -M_PI_2 + i * M_PI / 5, radius = d * (i % 2 ? 0.115 : 0.285);
        CGPoint p = CGPointMake(center.x + cos(a) * radius, center.y + sin(a) * radius);
        if (i) [star addLineToPoint:p]; else [star moveToPoint:p];
    }
    [star closePath];
    CGContextSetShadowWithColor(context, CGSizeZero, d * 0.10, [ALCyberRed() colorWithAlphaComponent:0.25].CGColor);
    [ALCyberRed() setFill]; [star fill];
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    UIBezierPath *slash = [UIBezierPath bezierPath];
    [slash moveToPoint:CGPointMake(d * 0.29, d * 0.67)];
    [slash addLineToPoint:CGPointMake(d * 0.72, d * 0.36)];
    slash.lineWidth = MAX(1.2, d * 0.035); [ALCyberText() setStroke]; [slash stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@implementation ALInjectedCyberSurface
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) { self.opaque = NO; self.backgroundColor = UIColor.clearColor; self.contentMode = UIViewContentModeRedraw; }
    return self;
}
- (void)setIlluminated:(BOOL)illuminated { _illuminated = illuminated; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGRect bounds = CGRectInset(self.bounds, 0.75, 0.75);
    UIBezierPath *edge = ALCutPanel(bounds, self.illuminated ? 14 : 10);
    [ALCyberSurfaceColor() setFill]; [edge fill];
    [[ALCyberRed() colorWithAlphaComponent:self.illuminated ? 0.62 : 0.24] setStroke];
    edge.lineWidth = 1; [edge stroke];
    if (self.illuminated) {
        UIBezierPath *rail = [UIBezierPath bezierPath];
        [rail moveToPoint:CGPointMake(1, 32)]; [rail addLineToPoint:CGPointMake(1, 1)];
        [rail addLineToPoint:CGPointMake(58, 1)]; rail.lineWidth = 2;
        [ALCyberRed() setStroke]; [rail stroke];
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSetStrokeColorWithColor(context, [ALCyberRed() colorWithAlphaComponent:0.08].CGColor);
        CGContextSetLineWidth(context, 0.5);
        for (CGFloat x = CGRectGetWidth(bounds) - 84; x < CGRectGetWidth(bounds) - 12; x += 9) {
            CGContextMoveToPoint(context, x, 12); CGContextAddLineToPoint(context, x - 22, 34);
        }
        CGContextStrokePath(context);
    }
}
@end

@implementation ALInjectedCyberButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO; self.backgroundColor = UIColor.clearColor; self.contentMode = UIViewContentModeRedraw;
        self.titleLabel.adjustsFontSizeToFitWidth = YES; self.titleLabel.minimumScaleFactor = 0.75;
        // This custom-drawn button also targets iOS 14 and does not use a configuration.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.contentEdgeInsets = UIEdgeInsetsMake(10, 10, 10, 10);
        self.imageEdgeInsets = UIEdgeInsetsMake(0, -5, 0, 5);
#pragma clang diagnostic pop
    }
    return self;
}
- (void)setPrimary:(BOOL)primary { _primary = primary; [self setNeedsDisplay]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self setNeedsDisplay]; }
- (void)setSelected:(BOOL)selected {
    if (self.selected == selected) return;
    [super setSelected:selected];
    self.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    [self setNeedsDisplay];
}
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.alpha = enabled ? 1 : 0.45; }
- (void)drawRect:(CGRect)rect {
    UIBezierPath *edge = ALCutPanel(CGRectInset(self.bounds, 0.75, 0.75), 8);
    UIColor *fill = self.highlighted ? ALHex(0xD8ECF8) : self.selected ? ALHex(0xDCEFF9) : self.primary ? ALHex(0xE6F5FC) : ALHex(0xF8FBFD);
    [fill setFill]; [edge fill];
    [[ALCyberRed() colorWithAlphaComponent:self.selected ? 0.95 : self.primary ? 0.62 : 0.28] setStroke];
    edge.lineWidth = 1; [edge stroke];
    if (self.selected || self.primary) {
        CGRect marker = CGRectMake(1, 12, 2, MAX(8, self.bounds.size.height - 24));
        [ALCyberRed() setFill]; UIRectFill(marker);
    }
}
@end

@implementation ALInjectedBubbleButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
    return [super pointInside:point withEvent:event] &&
        hypot(point.x - CGRectGetMidX(self.bounds), point.y - CGRectGetMidY(self.bounds)) <= radius;
}
@end
