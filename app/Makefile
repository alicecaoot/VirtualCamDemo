include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualCamDemo

VirtualCamDemo_FILES = main.m AppDelegate.m CameraViewController.m ../iosurface_buffer.c ../video_to_iosurface.m
VirtualCamDemo_CFLAGS = -fobjc-arc -Wall -I..
VirtualCamDemo_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage IOSurface QuartzCore
VirtualCamDemo_CODESIGN_FLAGS = -Sentitlements.plist
VirtualCamDemo_INSTALL_PATH = /Applications
# Theos 会自动拾取同目录 Info.plist

include $(THEOS_MAKE_PATH)/application.mk
