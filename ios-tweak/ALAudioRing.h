#import <Foundation/Foundation.h>

@interface ALAudioRing : NSObject

@property(nonatomic, assign, getter=isActive) BOOL active;
- (void)clear;
- (void)pushSamples:(const float *)samples count:(NSUInteger)count
           channels:(NSUInteger)channels sampleRate:(double)sampleRate;
- (BOOL)popSamples:(float *)output count:(NSUInteger)count
          channels:(NSUInteger)channels sampleRate:(double)sampleRate;

@end
