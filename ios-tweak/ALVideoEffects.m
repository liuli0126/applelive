#import "ALVideoEffects.h"
#import <os/log.h>
#include <math.h>

CIImage *ALApplyFisheye(CIImage *image, BOOL enabled) {
    if (!image || !enabled) return image;
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent) || CGRectIsNull(extent) ||
        !isfinite(extent.origin.x) || !isfinite(extent.origin.y) ||
        !isfinite(extent.size.width) || !isfinite(extent.size.height)) return image;

    static CIKernel *kernel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Inverse equidistant projection: a destination radius represents an
        // angle; tan(angle) locates the corresponding rectilinear source ray.
        // The diagonal sets the radius for both axes, so portrait images do
        // not get an elliptical lens. In-bounds samples always stay in-bounds.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        kernel = [CIKernel kernelWithString:
            @"kernel vec4 appleLiveFisheye(sampler source, vec2 center, float radius, vec4 bounds) {"
             "  vec2 position = destCoord();"
             "  if (position.x < bounds.x || position.y < bounds.y ||"
             "      position.x >= bounds.x + bounds.z || position.y >= bounds.y + bounds.w)"
             "    return vec4(0.0);"
             "  vec2 delta = position - center;"
             "  float r = length(delta) / radius;"
             "  float theta = 1.0471975512;"
             "  float sourceRadius = tan(min(r, 1.0) * theta) / 1.7320508076;"
             "  vec2 location = center + delta * (sourceRadius / max(r, 0.00001));"
             "  return sample(source, samplerTransform(source, location));"
             "}"];
#pragma clang diagnostic pop
        if (!kernel) os_log_error(OS_LOG_DEFAULT, "[AppleLive] fisheye kernel unavailable");
    });
    if (!kernel) return image;
    CGFloat radius = hypot(extent.size.width, extent.size.height) * 0.5;
    CIVector *center = [CIVector vectorWithX:CGRectGetMidX(extent) Y:CGRectGetMidY(extent)];
    CIImage *warped = [kernel applyWithExtent:extent roiCallback:^CGRect(int index, CGRect rect) {
        // A curved output tile may sample beyond its own rectangle. Returning
        // the finite input extent avoids seams and missing pixels at tile edges.
        (void)index; (void)rect;
        return extent;
    } arguments:@[image, center, @(radius), [CIVector vectorWithCGRect:extent]]];
    // The kernel explicitly returns transparency outside the source rectangle.
    // A crop matching the declared extent can be optimized away by Core Image.
    return warped ?: image;
}
