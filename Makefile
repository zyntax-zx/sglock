export THEOS_DEVICE_IP = 127.0.0.1
export THEOS_DEVICE_PORT = 2222
export ARCHS = arm64
export TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = sglock

sglock_FILES = Tweak.mm
sglock_CFLAGS = -fobjc-arc -std=c++17
sglock_LDFLAGS =

include $(THEOS_MAKE_PATH)/tweak.mk
