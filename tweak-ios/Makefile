TARGET := iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YouThibz

YouThibz_FILES = $(wildcard Sources/*.x)
YouThibz_CFLAGS = -fobjc-arc
YouThibz_FRAMEWORKS = UIKit SystemConfiguration AVFoundation Photos

include $(THEOS_MAKE_PATH)/tweak.mk
