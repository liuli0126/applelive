#import "ALVideoEffects.h"
#import <os/log.h>
#include <math.h>

CIImage *ALApplyFisheye(CIImage *image, BOOL enabled, CGFloat strength) {
    if (!image || !enabled) return image;
    strength = isfinite(strength) ? fmax(0, fmin(100, strength)) : 75;
    if (strength == 0) return image;
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
            @"kernel vec4 appleLiveFisheye(sampler source, vec2 center, float radius, vec4 bounds, float theta, float edgeTangent) {"
             "  vec2 position = destCoord();"
             "  if (position.x < bounds.x || position.y < bounds.y ||"
             "      position.x >= bounds.x + bounds.z || position.y >= bounds.y + bounds.w)"
             "    return vec4(0.0);"
             "  vec2 delta = position - center;"
             "  float r = length(delta) / radius;"
             "  float sourceRadius = tan(min(r, 1.0) * theta) / edgeTangent;"
             "  vec2 location = center + delta * (sourceRadius / max(r, 0.00001));"
             "  return sample(source, samplerTransform(source, location));"
             "}"];
#pragma clang diagnostic pop
        if (!kernel) os_log_error(OS_LOG_DEFAULT, "[AppleLive] fisheye kernel unavailable");
    });
    if (!kernel) return image;
    CGFloat radius = hypot(extent.size.width, extent.size.height) * 0.5;
    // Up to 160 degrees diagonally: stronger than the original 120-degree
    // preset while remaining safely below tan(pi/2). Both arguments are
    // uniforms, so dragging changes parameters without recompiling the kernel.
    CGFloat theta = (80.0 * M_PI / 180.0) * strength / 100.0;
    CIVector *center = [CIVector vectorWithX:CGRectGetMidX(extent) Y:CGRectGetMidY(extent)];
    CIImage *warped = [kernel applyWithExtent:extent roiCallback:^CGRect(int index, CGRect rect) {
        // A curved output tile may sample beyond its own rectangle. Returning
        // the finite input extent avoids seams and missing pixels at tile edges.
        (void)index; (void)rect;
        return extent;
    } arguments:@[image, center, @(radius), [CIVector vectorWithCGRect:extent], @(theta), @(tan(theta))]];
    // The kernel explicitly returns transparency outside the source rectangle.
    // A crop matching the declared extent can be optimized away by Core Image.
    return warped ?: image;
}
