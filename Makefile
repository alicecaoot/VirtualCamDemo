# Aggregate: tweak (越狱注入) + app (可打 IPA 的演示 App)
# 用法见 build_ipa.sh

export TARGET := iphone:clang:latest:14.0
export ARCHS := arm64

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak app

include $(THEOS_MAKE_PATH)/aggregate.mk
