TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualCamDemo

# v0.3: no IOSurface / camera hook — AVPlayer only (works on TrollStore, non-jailbreak)
VirtualCamDemo_FILES = main.m AppDelegate.m CameraViewController.m
VirtualCamDemo_CFLAGS = -fobjc-arc -Wall
VirtualCamDemo_FRAMEWORKS = UIKit Foundation AVFoundation AVKit PhotosUI UniformTypeIdentifiers QuartzCore
VirtualCamDemo_CODESIGN_FLAGS = -Sentitlements.plist
VirtualCamDemo_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
