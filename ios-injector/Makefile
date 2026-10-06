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
    ../ios-tweak/ALColorPipeline.m \
    ../ios-tweak/ALVideoEffects.m \
    ALMediaPlayer.m \
    ALMediaPanel.m \
    ALCyberTheme.m \
    ALSourceSettings.m \
    ALPreview.m \
    ALSampleAudio.m \
    ALUSBReceiver.m \
    ALExternalCamera.m \
    ALUVCFrame.m \
    ALAudioUnitBridge.m \
    ../.build/fishhook/fishhook.m \
    ../ios-tweak/ALVirtualCamera.m
AppleLive_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics VideoToolbox AudioToolbox QuartzCore Photos PhotosUI UniformTypeIdentifiers Security ImageIO Network IOKit
FFMPEG_ROOT = $(THEOS_PROJECT_DIR)/../.build/ios-ffmpeg/universal
UVC_ROOT = $(THEOS_PROJECT_DIR)/../.build/ios-uvc
AppleLive_LDFLAGS = -L$(FFMPEG_ROOT)/lib -lavformat -lavcodec -lswresample -lswscale -lavutil -lz -lbz2 -liconv -L$(UVC_ROOT)/lib -luvc -lusb-1.0
AppleLive_CFLAGS = -fobjc-arc -fvisibility=hidden -DAPPLELIVE_STANDALONE=1 \
    -include $(THEOS_PROJECT_DIR)/ALInjectorPrefix.h -I$(THEOS_PROJECT_DIR)/../ios-tweak \
    -I$(THEOS_PROJECT_DIR) -I$(FFMPEG_ROOT)/include -I$(THEOS_PROJECT_DIR)/../.build/fishhook -I$(UVC_ROOT)/include
AppleLive_CCFLAGS = $(AppleLive_CFLAGS)

include $(THEOS_MAKE_PATH)/library.mk
