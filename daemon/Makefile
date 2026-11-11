include $(THEOS)/makefiles/common.mk

TOOL_NAME = lainbridged
lainbridged_FILES = main.m
lainbridged_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
lainbridged_FRAMEWORKS = Foundation
lainbridged_CODESIGN_FLAGS = -Sent.plist
lainbridged_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
