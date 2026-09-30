#import <Foundation/Foundation.h>

FOUNDATION_EXPORT const uint32_t ALVideoType;
FOUNDATION_EXPORT const uint32_t ALAudioType;
FOUNDATION_EXPORT const NSUInteger ALVideoHeaderLength;
FOUNDATION_EXPORT const NSUInteger ALAudioHeaderLength;

typedef void (^ALVideoNALHandler)(NSData *nalData, uint32_t sequence, uint32_t flags,
                                  uint32_t width, uint32_t height);
typedef void (^ALAudioPCMHandler)(const float *samples, NSUInteger sampleCount,
                                  uint32_t channels, double sampleRate);
