TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualCamDemo

# Headers are injected into the SDK by CI / scripts/inject_iosurface_headers.sh
# Do NOT use -F vendor (shadows incomplete public framework and breaks UIKit/CoreImage modules)
VirtualCamDemo_FILES = main.m AppDelegate.m CameraViewController.m ../iosurface_buffer.c ../video_to_iosurface.m
VirtualCamDemo_CFLAGS = -fobjc-arc -Wall -I..
VirtualCamDemo_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage QuartzCore IOSurface
VirtualCamDemo_CODESIGN_FLAGS = -Sentitlements.plist
VirtualCamDemo_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
