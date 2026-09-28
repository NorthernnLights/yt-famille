TARGET := iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTPerso

YTPerso_FILES = $(wildcard Sources/*.x)
YTPerso_CFLAGS = -fobjc-arc
YTPerso_FRAMEWORKS = UIKit SystemConfiguration

include $(THEOS_MAKE_PATH)/tweak.mk
