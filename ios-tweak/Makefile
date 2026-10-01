ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppleLive

AppleLive_FILES = Tweak.xm \
    ALStreamClient.m \
    ALVideoDecoder.m \
    ALFrameStore.m \
    ALAudioRing.m \
    ALControls.m \
    ALConnection.m \
    ALFloatingPanel.m \
    ALVirtualCamera.m

AppleLive_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics VideoToolbox AudioToolbox
AppleLive_LIBRARIES = substrate
AppleLive_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
AppleLive_CCFLAGS = $(AppleLive_CFLAGS)

INSTALL_TARGET_PROCESSES = mediaserverd

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = AppleLiveSetup
AppleLiveSetup_FILES = ALConnectionTool.m ALConnection.m
AppleLiveSetup_FRAMEWORKS = Foundation
AppleLiveSetup_CFLAGS = -fobjc-arc
AppleLiveSetup_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
