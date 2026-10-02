#import <UIKit/UIKit.h>
#include <math.h>

// The injector is a standalone dylib, so keep the small brand mark vector-only
// and draw it at runtime instead of depending on an app bundle asset.
static UIImage *ALBrandMarkImage(CGSize size) {
    CGFloat dimension = MAX(24.0, MIN(size.width, size.height));
    CGSize canvas = CGSizeMake(dimension, dimension);
    UIGraphicsBeginImageContextWithOptions(canvas, YES, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect bounds = CGRectMake(0.5, 0.5, dimension - 1, dimension - 1);
    CGFloat radius = dimension * 0.22;
    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0.015 alpha:1].CGColor);
    CGContextFillPath(context);
    UIBezierPath *background = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius];
    [[UIColor colorWithWhite:0.015 alpha:1] setFill];
    [background fill];
    [[UIColor colorWithWhite:0.54 alpha:1] setStroke];
    background.lineWidth = MAX(1, dimension * 0.035);
    [background stroke];

    CGPoint center = CGPointMake(dimension * 0.5, dimension * 0.54);
    CGFloat outer = dimension * 0.34;
    CGFloat inner = outer * 0.34;
    UIBezierPath *star = [UIBezierPath bezierPath];
    for (NSInteger index = 0; index < 10; index++) {
        CGFloat angle = -M_PI_2 + index * M_PI / 5.0;
        CGFloat radius = (index % 2 == 0) ? outer : inner;
        CGPoint point = CGPointMake(center.x + cos(angle) * radius, center.y + sin(angle) * radius);
        if (index == 0) [star moveToPoint:point]; else [star addLineToPoint:point];
    }
    [star closePath];
    [[UIColor whiteColor] setFill];
    [star fill];

    // A pair of short slashes echoes the supplied StarLive wordmark at icon size.
    [[UIColor whiteColor] setStroke];
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineWidth(context, MAX(1.2, dimension * 0.045));
    CGContextMoveToPoint(context, dimension * 0.18, dimension * 0.68);
    CGContextAddLineToPoint(context, dimension * 0.38, dimension * 0.59);
    CGContextMoveToPoint(context, dimension * 0.62, dimension * 0.39);
    CGContextAddLineToPoint(context, dimension * 0.83, dimension * 0.30);
    CGContextStrokePath(context);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}
