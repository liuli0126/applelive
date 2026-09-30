ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppleLive

AppleLive_FILES = Tweak.xm \
    ALStreamClient.m \
    ALVideoDecoder.m \
    ALFrameStore.m \
    ALAudioRing.m \
    ALVirtualCamera.m

AppleLive_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo VideoToolbox AudioToolbox
AppleLive_LIBRARIES = substrate
AppleLive_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
AppleLive_CCFLAGS = $(AppleLive_CFLAGS)

INSTALL_TARGET_PROCESSES = mediaserverd

include $(THEOS_MAKE_PATH)/tweak.mk
