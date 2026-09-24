TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualCamDemo

VirtualCamDemo_FILES = main.m AppDelegate.m CameraViewController.m ../iosurface_buffer.c ../video_to_iosurface.m
VirtualCamDemo_CFLAGS = -fobjc-arc -Wall -I..
VirtualCamDemo_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage QuartzCore IOSurface PhotosUI UniformTypeIdentifiers MobileCoreServices
VirtualCamDemo_CODESIGN_FLAGS = -Sentitlements.plist
VirtualCamDemo_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
