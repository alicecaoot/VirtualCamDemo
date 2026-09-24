# Aggregate root — force modern arm64 iOS
export TARGET := iphone:clang:latest:14.0
export ARCHS := arm64
export THEOS_PACKAGE_SCHEME ?=

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak app

include $(THEOS_MAKE_PATH)/aggregate.mk
