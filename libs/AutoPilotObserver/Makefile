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
OUT_STATIC := $(BUILD)/libAutoPilotObserver.a
OUT_DYLIB  := $(BUILD)/libAutoPilotObserver.dylib

SWIFT_SOURCES := Sources/IPCServer.swift Sources/ViewSerializer.swift Sources/RPCHandler.swift
OBJC_SOURCE   := Sources/Observer.m

.PHONY: all clean device dylib

all: $(OUT_STATIC)

device:
	$(MAKE) FLAVOR=device

# Dylib target — SOLO para simulator (iOS device bloquea DYLD injection).
# Se inyecta vía SIMCTL_CHILD_DYLD_INSERT_LIBRARIES al lanzar el app, sin
# recompilar el binario del app. Para device físico usar el target
# `all` (static) con `-force_load` en el build del app.
dylib: $(OUT_DYLIB)

$(OUT_STATIC): $(BUILD)/objs/Observer.o $(SWIFT_SOURCES)
	mkdir -p $(BUILD)/objs
	cd $(BUILD)/objs && xcrun --sdk $(SDK_NAME) swiftc \
	    -target $(TARGET) \
	    -emit-object -parse-as-library \
	    -module-name AutoPilotObserver \
	    -sdk $(SDK) \
	    ../../Sources/IPCServer.swift \
	    ../../Sources/ViewSerializer.swift \
	    ../../Sources/RPCHandler.swift
	xcrun ar rcs $(OUT_STATIC) $(BUILD)/objs/*.o

$(OUT_DYLIB): $(BUILD)/objs/Observer.o $(SWIFT_SOURCES)
	@if [ "$(FLAVOR)" = "device" ]; then \
	    echo "error: dylib target no aplica a device físico (iOS sandbox bloquea DYLD injection)"; \
	    echo "       usar el target 'all' (.a static) con -force_load en el build del app"; \
	    exit 1; \
	fi
	mkdir -p $(BUILD)/objs
	cd $(BUILD)/objs && xcrun --sdk $(SDK_NAME) swiftc \
	    -target $(TARGET) \
	    -emit-object -parse-as-library \
	    -module-name AutoPilotObserver \
	    -sdk $(SDK) \
	    ../../Sources/IPCServer.swift \
	    ../../Sources/ViewSerializer.swift \
	    ../../Sources/RPCHandler.swift
	xcrun --sdk $(SDK_NAME) clang \
	    -dynamiclib \
	    -target $(TARGET) \
	    -isysroot $(SDK) \
	    -install_name @rpath/libAutoPilotObserver.dylib \
	    -framework UIKit \
	    -framework Foundation \
	    $(BUILD)/objs/*.o \
	    -o $(OUT_DYLIB)

$(BUILD)/objs/Observer.o: $(OBJC_SOURCE)
	mkdir -p $(BUILD)/objs
	xcrun --sdk $(SDK_NAME) clang \
	    -target $(TARGET) \
	    -isysroot $(SDK) \
	    -c -fobjc-arc \
	    $(OBJC_SOURCE) -o $@

clean:
	rm -rf build build-device
