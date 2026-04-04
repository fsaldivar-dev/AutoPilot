#!/bin/bash
# Build libcameramock.so for Android arm64 and x86_64 (emulator)
# Requires: ANDROID_HOME with NDK installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

# Find latest NDK
NDK_DIR=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
if [ -z "$NDK_DIR" ]; then
    echo "Error: No NDK found in $ANDROID_HOME/ndk/"
    exit 1
fi

TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/darwin-x86_64"
SYSROOT="$TOOLCHAIN/sysroot"
OUT_DIR="$SCRIPT_DIR/build"
mkdir -p "$OUT_DIR"

echo "NDK: $NDK_DIR"

# Build for arm64-v8a (real devices + newer emulators)
echo "Building arm64-v8a..."
"$TOOLCHAIN/bin/aarch64-linux-android26-clang" \
    -shared -fPIC -O2 \
    -I"$SYSROOT/usr/include" \
    -o "$OUT_DIR/libcameramock-arm64.so" \
    "$SCRIPT_DIR/agent.c" \
    -llog -lc

# Build for x86_64 (emulators)
echo "Building x86_64..."
"$TOOLCHAIN/bin/x86_64-linux-android26-clang" \
    -shared -fPIC -O2 \
    -I"$SYSROOT/usr/include" \
    -o "$OUT_DIR/libcameramock-x86_64.so" \
    "$SCRIPT_DIR/agent.c" \
    -llog -lc

echo ""
echo "Built:"
ls -lh "$OUT_DIR/"*.so
echo ""
echo "Deploy to device:"
echo "  adb push $OUT_DIR/libcameramock-arm64.so /data/local/tmp/libcameramock.so  # real device"
echo "  adb push $OUT_DIR/libcameramock-x86_64.so /data/local/tmp/libcameramock.so # emulator"
