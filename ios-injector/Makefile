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
    ALMediaPlayer.m \
    ALMediaPanel.m \
    ALPreview.m \
    ALSampleAudio.m \
    ALUSBReceiver.m \
    ALAudioUnitBridge.m \
    ../.build/fishhook/fishhook.c \
    ../ios-tweak/ALVirtualCamera.m
AppleLive_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics VideoToolbox AudioToolbox QuartzCore Photos PhotosUI UniformTypeIdentifiers Security ImageIO Network
FFMPEG_ROOT = $(THEOS_PROJECT_DIR)/../.build/ios-ffmpeg/universal
AppleLive_LDFLAGS = -L$(FFMPEG_ROOT)/lib -lavformat -lavcodec -lswresample -lswscale -lavutil -lz -lbz2 -liconv
AppleLive_CFLAGS = -fobjc-arc -fvisibility=hidden -DAPPLELIVE_STANDALONE=1 \
    -include $(THEOS_PROJECT_DIR)/ALInjectorPrefix.h -I$(THEOS_PROJECT_DIR)/../ios-tweak \
    -I$(THEOS_PROJECT_DIR) -I$(FFMPEG_ROOT)/include -I$(THEOS_PROJECT_DIR)/../.build/fishhook
AppleLive_CCFLAGS = $(AppleLive_CFLAGS)

include $(THEOS_MAKE_PATH)/library.mk
