#!/bin/bash
# run-camera-test.sh — Run camera injection E2E on any emulator
# Usage: ./scripts/ci/run-camera-test.sh [api-level]
# Requires: emulator running, adb accessible, CLI built
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
BINARY="$REPO/cli/.build/debug/auto-android"
PKG="dev.autopilot.test.CameraTestApp"
APK="$REPO/Demo/Android/CameraTestApp/app/build/outputs/apk/debug/app-debug.apk"
AGENT_APK="$REPO/agent/app/build/outputs/apk/debug/app-debug.apk"

export PATH="$PATH:$ANDROID_HOME/platform-tools"

API=$($ADB shell getprop ro.build.version.sdk | tr -d '\r')
echo "========================================"
echo "  Camera Injection E2E — API $API"
echo "  $(date '+%Y-%m-%d %H:%M')"
echo "========================================"
echo ""

# Install apps if needed
if ! $ADB shell pm list packages | grep -q "$PKG"; then
    echo "Installing CameraTestApp..."
    $ADB install -r "$APK"
fi
if ! $ADB shell pm list packages | grep -q "dev.autopilot.agent"; then
    if [ -f "$AGENT_APK" ]; then
        echo "Installing agent..."
        $ADB install -r "$AGENT_APK"
    fi
fi

# Setup
$ADB shell am force-stop $PKG 2>/dev/null || true
sleep 1

# Forward socket
$ADB forward tcp:9008 localabstract:autopilot 2>/dev/null || true

# Launch app
echo "[SETUP] Launching app..."
$ADB shell am start -n "$PKG/.MainActivity" 2>&1
sleep 5

# Inject camera mock
echo "[SETUP] Injecting camera mock (JVMTI)..."
cd "$REPO"
$BINARY camera start scripts/demo-images/qr-autopilot.png --package $PKG 2>&1 || {
    echo "WARN: camera start failed, trying manual injection..."
    $ADB push agent/camera-mock-native/build/libcameramock.so /data/local/tmp/libcameramock.so
    $ADB push agent/camera-mock-kotlin/build/autopilot-camera-mock.dex /data/local/tmp/autopilot-camera-mock.dex
    $ADB push scripts/demo-images/qr-autopilot.png /data/local/tmp/camera.jpg
    $ADB shell run-as $PKG rm -f libcameramock.so autopilot-camera-mock.dex camera.jpg
    $ADB shell run-as $PKG cp /data/local/tmp/libcameramock.so ./libcameramock.so
    $ADB shell run-as $PKG cp /data/local/tmp/autopilot-camera-mock.dex ./autopilot-camera-mock.dex
    $ADB shell run-as $PKG chmod 444 autopilot-camera-mock.dex
    $ADB shell run-as $PKG cp /data/local/tmp/camera.jpg ./camera.jpg
    PID=$($ADB shell pidof $PKG | tr -d '\r\n')
    DATADIR=$($ADB shell run-as $PKG pwd | tr -d '\r\n')
    $ADB shell cmd activity attach-agent $PID "$DATADIR/libcameramock.so=$DATADIR/camera.jpg"
}
sleep 3

# Wait for wrapper to install
echo "[SETUP] Waiting for ImageReader wrapper..."
sleep 3

OUTDIR="screenshots/api${API}"
mkdir -p "$OUTDIR"
PASS=0
FAIL=0
SKIP=0

run_test() {
    local name="$1"
    local tab="$2"
    local button="$3"
    local expect="$4"
    local img="${5:-}"

    echo ""
    echo "--- TEST: $name ---"

    # Hot-swap image if specified
    if [ -n "$img" ]; then
        $ADB push "$REPO/scripts/demo-images/$img" /data/local/tmp/camera.jpg 2>/dev/null
        $ADB shell run-as $PKG cp /data/local/tmp/camera.jpg ./camera.jpg 2>/dev/null
        sleep 1
    fi

    # Switch tab (use legacy uiautomator)
    if [ "$tab" != "-" ]; then
        $BINARY --legacy tap "$tab" 2>&1 || echo "WARN: tab tap failed"
        sleep 4
    fi

    # Take screenshot
    $BINARY --legacy screenshot "$OUTDIR/${name}-preview.png" 2>&1 || true

    # Tap capture button
    $BINARY --legacy tap "$button" 2>&1 || {
        echo "  FAIL: could not tap '$button'"
        FAIL=$((FAIL+1))
        return
    }
    sleep 5

    # Check result
    $BINARY --legacy screenshot "$OUTDIR/${name}-result.png" 2>&1 || true

    if $BINARY --legacy exists "$expect" 2>&1 | grep -q "true\|Found\|exists"; then
        echo "  PASS: found '$expect'"
        PASS=$((PASS+1))
    elif $ADB logcat -d 2>&1 | grep -q "$expect"; then
        echo "  PASS: found '$expect' in logcat"
        PASS=$((PASS+1))
    else
        echo "  FAIL: '$expect' not found"
        FAIL=$((FAIL+1))
    fi
    $ADB logcat -c 2>/dev/null || true
}

# Run tests
run_test "camerax" "-" "Capturar Foto" "Foto capturada"
run_test "qr" "QR" "Escanear QR" "QR detectado" "qr-autopilot.png"
run_test "ocr" "OCR" "Reconocer Texto" "Texto detectado" "ocr-test.png"
run_test "intent" "Intent" "Capturar por Intent" "capturada" ""
run_test "id-front" "ID" "Capturar Frente de ID" "Frente de ID" "id-frente.png"

echo ""
echo "========================================"
echo "  API $API Results: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
echo "  Screenshots: $OUTDIR/"
echo "========================================"
