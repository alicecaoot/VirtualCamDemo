TARGET := iphone:clang:latest:14.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = VirtualCamDemo YourApp

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyFirstTweak

IOSURFACE_HEADER_ROOT = $(THEOS_PROJECT_DIR)/../vendor

MyFirstTweak_FILES = Tweak.x ../iosurface_buffer.c ../video_to_iosurface.m
MyFirstTweak_CFLAGS = -fobjc-arc -Wall -I.. -I$(IOSURFACE_HEADER_ROOT) -F$(IOSURFACE_HEADER_ROOT)
MyFirstTweak_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage QuartzCore
MyFirstTweak_LDFLAGS = -framework IOSurface
MyFirstTweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 VirtualCamDemo YourApp || true"
