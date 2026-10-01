#import <Foundation/Foundation.h>
@class ALAudioRing;
void ALInstallAudioUnitBridge(void);
void ALConfigureAudioUnitBridge(ALAudioRing *ring, BOOL active, BOOL muted);
void ALMarkAudioDelegate(void);
