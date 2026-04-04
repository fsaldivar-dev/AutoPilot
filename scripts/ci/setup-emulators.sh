#!/usr/bin/env bash
# setup-emulators.sh — Create AVDs for API levels 28-35
#
# Usage: ./scripts/ci/setup-emulators.sh
#
# Requires: ANDROID_HOME set, Android SDK installed

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"

SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

if [ ! -x "$SDKMANAGER" ]; then
    echo "ERROR: sdkmanager not found at $SDKMANAGER"
    echo "Install via: Android Studio → SDK Manager → SDK Tools → Android SDK Command-line Tools"
    exit 1
fi

# API levels matching our minSdk=28 through targetSdk=35
API_LEVELS=(28 29 31 33 35)
DEVICE="pixel_6"
ABI="google_apis;arm64-v8a"

echo "=== AutoPilot Emulator Setup ==="
echo "APIs: ${API_LEVELS[*]}"
echo "Device: $DEVICE"
echo ""

# Accept licenses
yes | "$SDKMANAGER" --licenses > /dev/null 2>&1 || true

for API in "${API_LEVELS[@]}"; do
    IMAGE="system-images;android-${API};${ABI}"
    AVD_NAME="autopilot-api${API}"

    echo "--- API $API ---"

    # Download system image
    if [ -d "$ANDROID_HOME/system-images/android-${API}/google_apis/arm64-v8a" ]; then
        echo "  System image already installed"
    else
        echo "  Downloading system image..."
        "$SDKMANAGER" "$IMAGE" || {
            echo "  WARNING: Failed to download $IMAGE, trying google_apis_playstore..."
            IMAGE="system-images;android-${API};google_apis_playstore;arm64-v8a"
            "$SDKMANAGER" "$IMAGE" || { echo "  SKIP: No image available for API $API"; continue; }
        }
    fi

    # Create AVD
    if "$AVDMANAGER" list avd -c 2>/dev/null | grep -q "^${AVD_NAME}$"; then
        echo "  AVD $AVD_NAME already exists"
    else
        echo "  Creating AVD $AVD_NAME..."
        echo "no" | "$AVDMANAGER" create avd \
            -n "$AVD_NAME" \
            -k "$IMAGE" \
            -d "$DEVICE" \
            --force
        echo "  Created $AVD_NAME"
    fi

    echo ""
done

echo "=== Setup complete ==="
echo "Available AVDs:"
"$AVDMANAGER" list avd -c 2>/dev/null | grep "autopilot-" || echo "  (none)"
echo ""
echo "To start an emulator:"
echo "  \$ANDROID_HOME/emulator/emulator -avd autopilot-api35 -no-snapshot-load"
