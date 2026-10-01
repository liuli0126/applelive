ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AppleLive
AppleLive_FILES = ../ios-tweak/Tweak.xm \
    ../ios-tweak/ALStreamClient.m \
    ../ios-tweak/ALVideoDecoder.m \
    ../ios-tweak/ALFrameStore.m \
    ../ios-tweak/ALAudioRing.m \
    ../ios-tweak/ALControls.m \
    ../ios-tweak/ALConnection.m \
    ../ios-tweak/ALFloatingPanel.m \
    ../ios-tweak/ALVirtualCamera.m
AppleLive_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics VideoToolbox AudioToolbox
AppleLive_CFLAGS = -fobjc-arc -fvisibility=hidden -DAPPLELIVE_STANDALONE=1 \
    -include $(THEOS_PROJECT_DIR)/ALInjectorPrefix.h -I$(THEOS_PROJECT_DIR)/../ios-tweak
AppleLive_CCFLAGS = $(AppleLive_CFLAGS)

include $(THEOS_MAKE_PATH)/library.mk
