# Build flavor: simulator (default) | device
FLAVOR ?= simulator

ifeq ($(FLAVOR),device)
  SDK_NAME := iphoneos
  ARCH     := arm64
  TARGET   := arm64-apple-ios17.0
  BUILD    := build-device
else
  SDK_NAME := iphonesimulator
  ARCH     := $(shell uname -m)
  TARGET   := $(ARCH)-apple-ios17.0-simulator
  BUILD    := build
endif

SDK := $(shell xcrun --sdk $(SDK_NAME) --show-sdk-path)
OUT := $(BUILD)/libAutoPilotObserver.a

SWIFT_SOURCES := Sources/IPCServer.swift Sources/ViewSerializer.swift Sources/RPCHandler.swift
OBJC_SOURCE   := Sources/Observer.m

.PHONY: all clean device

all: $(OUT)

device:
	$(MAKE) FLAVOR=device

$(OUT): $(BUILD)/objs/Observer.o $(SWIFT_SOURCES)
	mkdir -p $(BUILD)/objs
	cd $(BUILD)/objs && xcrun --sdk $(SDK_NAME) swiftc \
	    -target $(TARGET) \
	    -emit-object -parse-as-library \
	    -module-name AutoPilotObserver \
	    -sdk $(SDK) \
	    ../../Sources/IPCServer.swift \
	    ../../Sources/ViewSerializer.swift \
	    ../../Sources/RPCHandler.swift
	xcrun ar rcs $(OUT) $(BUILD)/objs/*.o

$(BUILD)/objs/Observer.o: $(OBJC_SOURCE)
	mkdir -p $(BUILD)/objs
	xcrun --sdk $(SDK_NAME) clang \
	    -target $(TARGET) \
	    -isysroot $(SDK) \
	    -c -fobjc-arc \
	    $(OBJC_SOURCE) -o $@

clean:
	rm -rf build build-device
