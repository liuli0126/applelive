#import "ALAudioUnitBridge.h"
#import "ALSampleAudio.h"
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#include <stdatomic.h>
#include "fishhook.h"

typedef struct {
    AudioUnit unit;
    AudioStreamBasicDescription format;
    float scratch[4096 * 8];
} ALUnitSlot;
static ALUnitSlot *gALUnits;
static os_unfair_lock gALUnitLock = OS_UNFAIR_LOCK_INIT;
static ALAudioRing *gALUnitRing;
static atomic_bool gALUnitActive, gALUnitMuted;
static OSStatus (*gALUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*gALUnitInitialize)(AudioUnit);
static OSStatus (*gALUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus (*gALUnitDispose)(AudioComponentInstance);

static void ALCacheInputUnit(AudioUnit unit) {
    AudioComponentDescription description = {0};
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component || AudioComponentGetDescription(component, &description) != noErr ||
        description.componentType != kAudioUnitType_Output ||
        (description.componentSubType != kAudioUnitSubType_RemoteIO && description.componentSubType != kAudioUnitSubType_VoiceProcessingIO)) return;
    AudioStreamBasicDescription format; UInt32 size = sizeof(format);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &size) != noErr) return;
    os_unfair_lock_lock(&gALUnitLock);
    ALUnitSlot *available = NULL;
    for (int i = 0; i < 16; i++) {
        if (gALUnits[i].unit == unit) { available = &gALUnits[i]; break; }
        if (!gALUnits[i].unit && !available) available = &gALUnits[i];
    }
    if (available) { available->unit = unit; available->format = format; }
    os_unfair_lock_unlock(&gALUnitLock);
}
static OSStatus ALUnitInitialize(AudioUnit unit) {
    OSStatus status = gALUnitInitialize(unit);
    if (status == noErr) ALCacheInputUnit(unit);
    return status;
}
static OSStatus ALUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                                 AudioUnitElement element, const void *data, UInt32 size) {
    OSStatus status = gALUnitSetProperty(unit, property, scope, element, data, size);
    if (status == noErr && property == kAudioUnitProperty_StreamFormat) ALCacheInputUnit(unit);
    return status;
}
static OSStatus ALUnitDispose(AudioComponentInstance unit) {
    os_unfair_lock_lock(&gALUnitLock);
    for (int i = 0; i < 16; i++) if (gALUnits[i].unit == unit) gALUnits[i].unit = NULL;
    os_unfair_lock_unlock(&gALUnitLock);
    return gALUnitDispose(unit);
}
static OSStatus ALUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                           UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    OSStatus status = gALUnitRender(unit, flags, time, bus, frames, buffers);
    if (status != noErr || bus != 1 || !buffers || !atomic_load(&gALUnitActive)) return status;
    os_unfair_lock_lock(&gALUnitLock);
    for (int i = 0; i < 16; i++) if (gALUnits[i].unit == unit) {
        ALUnitSlot *slot = &gALUnits[i];
        BOOL written = frames <= 4096 && ALWriteInjectedPCM(&slot->format, buffers, frames, gALUnitRing,
            atomic_load(&gALUnitMuted), slot->scratch, 4096 * 8);
        if (!written) for (UInt32 b = 0; b < buffers->mNumberBuffers; b++)
            if (buffers->mBuffers[b].mData) memset(buffers->mBuffers[b].mData, 0, buffers->mBuffers[b].mDataByteSize);
        break;
    }
    os_unfair_lock_unlock(&gALUnitLock);
    return status;
}
void ALConfigureAudioUnitBridge(ALAudioRing *ring, BOOL active, BOOL muted) {
    // The camera singleton owns the ring for the process lifetime.
    if (!gALUnitRing) gALUnitRing = ring;
    atomic_store(&gALUnitMuted, muted); atomic_store(&gALUnitActive, active);
}
void ALInstallAudioUnitBridge(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gALUnits = calloc(16, sizeof(ALUnitSlot));
        if (!gALUnits) return;
        struct rebinding hooks[] = {
            {"AudioUnitRender", (void *)ALUnitRender, (void **)&gALUnitRender},
            {"AudioUnitInitialize", (void *)ALUnitInitialize, (void **)&gALUnitInitialize},
            {"AudioUnitSetProperty", (void *)ALUnitSetProperty, (void **)&gALUnitSetProperty},
            {"AudioComponentInstanceDispose", (void *)ALUnitDispose, (void **)&gALUnitDispose},
        };
        rebind_symbols(hooks, sizeof(hooks) / sizeof(hooks[0]));
    });
}
