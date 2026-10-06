#import "ALVideoEffects.h"
#import "ALControls.h"
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL passed, const char *message) {
    if (!passed) { fprintf(stderr, "%s\n", message); exit(1); }
}

static void testControls(void) {
    NSString *key = @"AppleLive.Controls.v1";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id previous = [defaults objectForKey:key];
    [defaults removeObjectForKey:key];
    require(![ALLoadAppControls()[@"fisheye"] boolValue], "fresh installation defaults fisheye off");
    [defaults setObject:@{@"enabled":@YES, @"mirror":@YES, @"rotation":@2} forKey:key];
    NSMutableDictionary *controls = [ALLoadAppControls() mutableCopy];
    require(![controls[@"fisheye"] boolValue] && [controls[@"mirror"] boolValue] &&
            [controls[@"rotation"] intValue]==2, "upgrade keeps old controls and defaults fisheye off");
    __block BOOL observed = NO;
    ALObserveControls(^(NSDictionary *value) { observed = [value[@"fisheye"] boolValue]; });
    controls[@"fisheye"]=@YES;
    require(ALSaveAndPublishControls(controls) && observed, "enabling publishes immediately");
    require([ALLoadAppControls()[@"fisheye"] boolValue], "enabled value persists");
    controls[@"fisheye"]=@NO;
    require(ALSaveAndPublishControls(controls) && !observed, "disabling publishes immediately");
    require(![ALLoadAppControls()[@"fisheye"] boolValue], "disabled value persists");
    require([ALLoadAppControls()[@"mirror"] boolValue] && [ALLoadAppControls()[@"rotation"] intValue]==2,
            "effect toggle does not reset other picture controls");
    if (previous) [defaults setObject:previous forKey:key]; else [defaults removeObjectForKey:key];
}

static void testGeometry(CIContext *context, size_t width, size_t height, CGPoint origin) {
    size_t length=width*height*4;
    NSMutableData *data=[NSMutableData dataWithLength:length];
    uint8_t *input=data.mutableBytes;
    for(size_t y=0;y<height;y++) for(size_t x=0;x<width;x++) {
        size_t p=(y*width+x)*4;
        input[p]=(uint8_t)lround(255.0*x/(width-1));
        input[p+1]=(uint8_t)lround(255.0*y/(height-1));
        input[p+2]=90; input[p+3]=255;
    }
    CIImage *image=[CIImage imageWithBitmapData:data bytesPerRow:width*4
        size:CGSizeMake(width,height) format:kCIFormatRGBA8 colorSpace:NULL];
    image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(origin.x,origin.y)];
    CIImage *warped=ALApplyFisheye(image,YES);
    require(warped && warped!=image,"fisheye kernel must compile and produce a warped image");
    require(CGRectEqualToRect(warped.extent,image.extent),"effect preserves extent and origin");
    uint8_t *out=malloc(length);
    [context render:warped toBitmap:out rowBytes:width*4 bounds:image.extent format:kCIFormatRGBA8 colorSpace:NULL];
    size_t changed=0;
    for(size_t p=0;p<length;p+=4) {
        require(out[p+3]==255,"no transparent edges, holes or tile seams");
        require(abs(out[p+2]-90)<=1,"warp must not change constant channel values");
        if(abs(out[p]-input[p])>3 || abs(out[p+1]-input[p+1])>3) changed++;
    }
    require(changed>width*height/2,"fisheye visibly changes the picture beyond its center");
    // The production path may fit the warped image over a larger black canvas.
    // Declared extent alone must not let the warp leak into letterbox margins.
    size_t paddedWidth=width+32, paddedHeight=height+32;
    uint8_t *padded=calloc(paddedWidth*paddedHeight,4);
    [context render:warped toBitmap:padded rowBytes:paddedWidth*4
        bounds:CGRectInset(image.extent,-16,-16) format:kCIFormatRGBA8 colorSpace:NULL];
    for(size_t y=0;y<paddedHeight;y++) for(size_t x=0;x<paddedWidth;x++) {
        if(x<16 || y<16 || x>=width+16 || y>=height+16)
            require(padded[(y*paddedWidth+x)*4+3]==0,"fisheye must not paint outside the source rectangle");
    }
    free(padded);
    size_t center=(height/2*width+width/2)*4;
    require(abs(out[center]-input[center])<=1 && abs(out[center+1]-input[center+1])<=1,
            "center stays fixed");
    // The gradient encodes source coordinates. Check GPU samples against the
    // lens equation at interior points, including portrait and translated images.
    double radius=hypot((double)width,(double)height)/2;
    for(size_t y=height/8;y<height;y+=height/4) for(size_t x=width/8;x<width;x+=width/4) {
        double dx=x+.5-width/2.0, dy=y+.5-height/2.0;
        double r=hypot(dx,dy)/radius;
        double scale=r<.00001 ? 1 : tan(r*M_PI/3)/(tan(M_PI/3)*r);
        int red=(int)lround((width/2.0+dx*scale-.5)*255/(width-1));
        int green=(int)lround((height/2.0+dy*scale-.5)*255/(height-1));
        size_t p=(y*width+x)*4;
        require(abs(out[p]-red)<=2 && abs(out[p+1]-green)<=2,"GPU warp follows radial lens geometry");
    }
    for(int toggle=0;toggle<6;toggle++) {
        require(ALApplyFisheye(image,NO)==image,"disabled bypasses all filtering");
        [context render:ALApplyFisheye(image,NO) toBitmap:out rowBytes:width*4 bounds:image.extent format:kCIFormatRGBA8 colorSpace:NULL];
        require(memcmp(input,out,length)==0,"switching off restores the exact original frame");
        require(ALApplyFisheye(image,YES)!=image,"re-enabling still works");
    }
    fprintf(stderr,"PASS fisheye %zux%zu origin=%.0f,%.0f changed=%zu\n",width,height,origin.x,origin.y,changed);
    free(out);
}

static void writePreview(CIContext *context, NSString *path) {
    const int w=480,h=320;
    NSMutableData *data=[NSMutableData dataWithLength:w*h*4];
    uint8_t *p=data.mutableBytes;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        int i=(y*w+x)*4;
        BOOL line=x%40<2 || y%40<2;
        BOOL ring=fabs(hypot(x-w/2.0,y-h/2.0)-80)<2;
        p[i]=ring?250:line?95:18; p[i+1]=ring?160:line?200:25;
        p[i+2]=ring?60:line?235:35; p[i+3]=255;
    }
    CIImage *image=[CIImage imageWithBitmapData:data bytesPerRow:w*4 size:CGSizeMake(w,h)
        format:kCIFormatRGBA8 colorSpace:NULL];
    CIImage *right=[ALApplyFisheye(image,YES) imageByApplyingTransform:CGAffineTransformMakeTranslation(w+16,0)];
    CGRect canvas=CGRectMake(0,0,w*2+16,h);
    CIImage *background=[[CIImage imageWithColor:[CIColor colorWithRed:.02 green:.03 blue:.04]] imageByCroppingToRect:canvas];
    CIImage *comparison=[right imageByCompositingOverImage:[image imageByCompositingOverImage:background]];
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSError *error=nil;
    require([context writePNGRepresentationOfImage:comparison toURL:[NSURL fileURLWithPath:path]
        format:kCIFormatRGBA8 colorSpace:space options:@{} error:&error],"write visual comparison");
    CGColorSpaceRelease(space);
}

int main(int argc,char **argv) {
    @autoreleasepool {
        testControls();
        CIContext *context=[CIContext contextWithOptions:@{kCIContextWorkingColorSpace:NSNull.null,
            kCIContextOutputColorSpace:NSNull.null, kCIContextCacheIntermediates:@NO}];
        require(ALApplyFisheye(nil,YES)==nil,"nil input stays nil");
        CIImage *infinite=[CIImage imageWithColor:CIColor.blackColor];
        require(ALApplyFisheye(infinite,YES)==infinite,"unbounded input is rejected safely");
        testGeometry(context,256,192,CGPointZero);
        testGeometry(context,192,256,CGPointMake(18,-22));
        testGeometry(context,256,256,CGPointZero);
        if(argc>1) writePreview(context,[NSString stringWithUTF8String:argv[1]]);
        puts("PASS fisheye defaults, persistence, geometry, opacity and on/off restoration");
    }
    return 0;
}
