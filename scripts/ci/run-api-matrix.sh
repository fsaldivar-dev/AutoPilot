#!/usr/bin/env bash
# run-api-matrix.sh — Run CameraTestApp on each API level emulator
#
# Usage: ./scripts/ci/run-api-matrix.sh [--build]
#
# Prerequisites:
#   - Run setup-emulators.sh first
#   - APK built: Demo/Android/CameraTestApp/app/build/outputs/apk/debug/app-debug.apk

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"

EMULATOR="$ANDROID_HOME/emulator/emulator"
ADB="$ANDROID_HOME/platform-tools/adb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$PROJECT_ROOT/Demo/Android/CameraTestApp"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"
PKG="dev.autopilot.test.CameraTestApp"

API_LEVELS=(28 29 31 33 35)
BOOT_TIMEOUT=120  # seconds

# Build if requested
if [[ "${1:-}" == "--build" ]]; then
    echo "Building APK..."
    cd "$APP_DIR"
    ANDROID_HOME="$ANDROID_HOME" ./gradlew assembleDebug
    cd "$PROJECT_ROOT"
fi

if [ ! -f "$APK" ]; then
    echo "ERROR: APK not found at $APK"
    echo "Build first: cd Demo/Android/CameraTestApp && ./gradlew assembleDebug"
    exit 1
fi

RESULTS=()

wait_for_boot() {
    local timeout=$BOOT_TIMEOUT
    echo -n "  Waiting for boot"
    while [ $timeout -gt 0 ]; do
        if "$ADB" shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
            echo " OK"
            return 0
        fi
        echo -n "."
        sleep 2
        timeout=$((timeout - 2))
    done
    echo " TIMEOUT"
    return 1
}

for API in "${API_LEVELS[@]}"; do
    AVD_NAME="autopilot-api${API}"
    echo ""
    echo "========================================="
    echo "  Testing API $API ($AVD_NAME)"
    echo "========================================="

    # Check AVD exists
    if ! "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" list avd -c 2>/dev/null | grep -q "^${AVD_NAME}$"; then
        echo "  SKIP: AVD $AVD_NAME not found. Run setup-emulators.sh first."
        RESULTS+=("API $API: SKIP (no AVD)")
        continue
    fi

    # Kill any running emulator
    "$ADB" emu kill 2>/dev/null || true
    sleep 2

    # Start emulator
    echo "  Starting emulator..."
    "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-load -no-window -no-audio -gpu swiftshader_indirect &
    EMU_PID=$!

    if ! wait_for_boot; then
        RESULTS+=("API $API: FAIL (boot timeout)")
        kill $EMU_PID 2>/dev/null || true
        continue
    fi

    # Unlock screen
    "$ADB" shell input keyevent 82 2>/dev/null || true
    sleep 1

    # Install APK
    echo "  Installing APK..."
    if ! "$ADB" install -r "$APK" 2>&1; then
        RESULTS+=("API $API: FAIL (install)")
        "$ADB" emu kill 2>/dev/null || true
        continue
    fi

    # Launch app
    echo "  Launching $PKG..."
    "$ADB" shell am start -n "$PKG/.MainActivity" 2>/dev/null
    sleep 3

    # Grant camera permission
    "$ADB" shell pm grant "$PKG" android.permission.CAMERA 2>/dev/null || true
    sleep 1

    # Verify app is running
    if "$ADB" shell pidof "$PKG" 2>/dev/null | grep -q "[0-9]"; then
        echo "  App running on API $API"
        RESULTS+=("API $API: PASS")
    else
        echo "  App NOT running"
        RESULTS+=("API $API: FAIL (app crash)")
    fi

    # Take screenshot as evidence
    SCREENSHOT_DIR="$PROJECT_ROOT/scripts/ci/screenshots"
    mkdir -p "$SCREENSHOT_DIR"
    "$ADB" shell screencap -p /sdcard/screenshot.png 2>/dev/null
    "$ADB" pull /sdcard/screenshot.png "$SCREENSHOT_DIR/api${API}.png" 2>/dev/null || true

    # Cleanup
    "$ADB" shell am force-stop "$PKG" 2>/dev/null || true
    "$ADB" emu kill 2>/dev/null || true
    wait $EMU_PID 2>/dev/null || true
    sleep 2
done

# Summary
echo ""
echo "========================================="
echo "  API Matrix Results"
echo "========================================="
for result in "${RESULTS[@]}"; do
    echo "  $result"
done
echo ""

# Exit with failure if any test failed
for result in "${RESULTS[@]}"; do
    if echo "$result" | grep -q "FAIL"; then
        exit 1
    fi
done
