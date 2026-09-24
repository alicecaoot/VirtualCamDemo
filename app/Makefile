TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualCamDemo

# Public Xcode SDK lacks IOSurface headers — use vendored shims (link real framework)
IOSURFACE_HEADER_ROOT = $(THEOS_PROJECT_DIR)/../vendor

VirtualCamDemo_FILES = main.m AppDelegate.m CameraViewController.m ../iosurface_buffer.c ../video_to_iosurface.m
VirtualCamDemo_CFLAGS = -fobjc-arc -Wall -I.. -I$(IOSURFACE_HEADER_ROOT) -F$(IOSURFACE_HEADER_ROOT)
VirtualCamDemo_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage QuartzCore
# Link system IOSurface (binary exists; headers from vendor)
VirtualCamDemo_LDFLAGS = -framework IOSurface -F$(IOSURFACE_HEADER_ROOT)
VirtualCamDemo_CODESIGN_FLAGS = -Sentitlements.plist
VirtualCamDemo_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
