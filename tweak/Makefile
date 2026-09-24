INSTALL_TARGET_PROCESSES = YourApp

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyFirstTweak

MyFirstTweak_FILES = Tweak.x ../iosurface_buffer.c ../video_to_iosurface.m
MyFirstTweak_CFLAGS = -fobjc-arc -Wall -I..
MyFirstTweak_FRAMEWORKS = UIKit Foundation IOSurface AVFoundation CoreMedia CoreVideo CoreImage QuartzCore
MyFirstTweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 YourApp || true"
