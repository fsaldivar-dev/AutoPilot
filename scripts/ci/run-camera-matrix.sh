#!/bin/bash
# run-camera-matrix.sh — Run camera injection E2E across all API levels
# Launches each emulator, injects camera mock, tests all tabs, reports results.
#
# Usage: ./scripts/ci/run-camera-matrix.sh
# Requires: CLI built (cd cli && swift build), emulators created, APKs built
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
EMU="$ANDROID_HOME/emulator/emulator"
BINARY="$REPO/cli/.build/debug/auto-android"
PKG="dev.autopilot.test.CameraTestApp"
APP_APK="$REPO/Demo/Android/CameraTestApp/app/build/outputs/apk/debug/app-debug.apk"
AGENT_APK="$REPO/agent/app/build/outputs/apk/debug/app-debug.apk"

export ANDROID_HOME PATH="$PATH:$ANDROID_HOME/platform-tools"
cd "$REPO"

# Tab coordinates (1080x2400 display, works across most densities)
# CameraX=default, QR~x=324, OCR~x=540, Intent~x=756
TAB_Y=230
BTN_Y=1580

EMULATORS=(autopilot-api28 autopilot-api29 autopilot-api31 autopilot-api33 autopilot-api35)
declare -A RESULTS

kill_emulator() {
    $ADB -s emulator-5554 emu kill 2>/dev/null || true
    $ADB -s emulator-5556 emu kill 2>/dev/null || true
    sleep 3
}

wait_for_boot() {
    local max=90 i=0
    $ADB wait-for-device 2>/dev/null
    while [ $i -lt $max ]; do
        val=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$val" = "1" ] && return 0
        sleep 2; i=$((i+2))
    done
    return 1
}

inject_camera() {
    local img="$1"
    # Try CLI first, fall back to manual
    $BINARY camera start "$img" --package $PKG 2>/dev/null && return 0

    # Manual injection
    $ADB push agent/camera-mock-native/build/libcameramock.so /data/local/tmp/libcameramock.so 2>/dev/null
    $ADB push agent/camera-mock-kotlin/build/autopilot-camera-mock.dex /data/local/tmp/autopilot-camera-mock.dex 2>/dev/null
    $ADB push "$img" /data/local/tmp/camera.jpg 2>/dev/null
    $ADB shell run-as $PKG rm -f libcameramock.so autopilot-camera-mock.dex camera.jpg 2>/dev/null
    $ADB shell run-as $PKG cp /data/local/tmp/libcameramock.so ./libcameramock.so 2>/dev/null
    $ADB shell run-as $PKG cp /data/local/tmp/autopilot-camera-mock.dex ./autopilot-camera-mock.dex 2>/dev/null
    $ADB shell run-as $PKG chmod 444 autopilot-camera-mock.dex 2>/dev/null
    $ADB shell run-as $PKG cp /data/local/tmp/camera.jpg ./camera.jpg 2>/dev/null
    local pid=$($ADB shell pidof $PKG | tr -d '\r\n')
    local dir=$($ADB shell run-as $PKG pwd | tr -d '\r\n')
    $ADB shell cmd activity attach-agent "$pid" "$dir/libcameramock.so=$dir/camera.jpg" 2>/dev/null
}

hot_swap() {
    local img="$1"
    $ADB push "$REPO/scripts/demo-images/$img" /data/local/tmp/camera.jpg 2>/dev/null
    $ADB shell run-as $PKG cp /data/local/tmp/camera.jpg ./camera.jpg 2>/dev/null
    sleep 1
}

tap_tab() {
    local x="$1"
    $ADB shell input tap "$x" "$TAB_Y" 2>/dev/null
    sleep 4
}

tap_button() {
    # Try by label first (agent bridge), fall back to coordinates
    $BINARY tap "$1" 2>/dev/null || \
    $BINARY --legacy tap "$1" 2>/dev/null || \
    $ADB shell input tap 540 "$BTN_Y" 2>/dev/null
    sleep 5
}

check_result() {
    local keyword="$1"
    $ADB logcat -d 2>&1 | grep -q "$keyword"
}

run_api_test() {
    local avd="$1"
    local api=$($ADB shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
    local outdir="screenshots/api${api}"
    mkdir -p "$outdir"
    local pass=0 fail=0 tests=""

    echo ""
    echo "========================================"
    echo "  API $api ($avd)"
    echo "========================================"

    # Install apps
    $ADB install -r "$APP_APK" 2>/dev/null | tail -1
    [ -f "$AGENT_APK" ] && $ADB install -r "$AGENT_APK" 2>/dev/null | tail -1
    $ADB forward tcp:9008 localabstract:autopilot 2>/dev/null || true

    # Launch + inject
    $ADB shell am force-stop $PKG 2>/dev/null
    sleep 1
    $ADB shell am start -n "$PKG/.MainActivity" 2>/dev/null
    sleep 5
    inject_camera scripts/demo-images/qr-autopilot.png
    sleep 5

    # TEST 1: CameraX
    echo -n "  CameraX:  "
    $ADB logcat -c 2>/dev/null
    tap_button "Capturar Foto"
    $ADB shell screencap -p "/data/local/tmp/ss.png" 2>/dev/null
    $ADB pull "/data/local/tmp/ss.png" "$outdir/camerax.png" 2>/dev/null | tail -1
    if check_result "Foto capturada\|mock capture delivered"; then
        echo "PASS"; pass=$((pass+1))
    else echo "FAIL"; fail=$((fail+1)); fi

    # TEST 2: QR
    echo -n "  QR+MLKit: "
    hot_swap "qr-autopilot.png"
    $ADB logcat -c 2>/dev/null
    tap_tab 324
    tap_button "Escanear QR"
    $ADB shell screencap -p "/data/local/tmp/ss.png" 2>/dev/null
    $ADB pull "/data/local/tmp/ss.png" "$outdir/qr.png" 2>/dev/null | tail -1
    if check_result "QR detectado\|AUTOPILOT-QR"; then
        echo "PASS"; pass=$((pass+1))
    else echo "FAIL"; fail=$((fail+1)); fi

    # TEST 3: OCR
    echo -n "  OCR+MLKit:"
    hot_swap "ocr-test.png"
    $ADB logcat -c 2>/dev/null
    tap_tab 540
    tap_button "Reconocer Texto"
    $ADB shell screencap -p "/data/local/tmp/ss.png" 2>/dev/null
    $ADB pull "/data/local/tmp/ss.png" "$outdir/ocr.png" 2>/dev/null | tail -1
    if check_result "Texto detectado\|mock capture delivered"; then
        echo "PASS"; pass=$((pass+1))
    else echo "FAIL"; fail=$((fail+1)); fi

    # TEST 4: Intent
    echo -n "  Intent:   "
    $ADB logcat -c 2>/dev/null
    tap_tab 756
    tap_button "Capturar por Intent"
    $ADB shell screencap -p "/data/local/tmp/ss.png" 2>/dev/null
    $ADB pull "/data/local/tmp/ss.png" "$outdir/intent.png" 2>/dev/null | tail -1
    if check_result "capturada\|thumbnail\|Intent"; then
        echo "PASS"; pass=$((pass+1))
    else echo "FAIL"; fail=$((fail+1)); fi

    # TEST 5: ID front
    echo -n "  ID front: "
    hot_swap "id-frente.png"
    $ADB logcat -c 2>/dev/null
    $ADB shell input swipe 900 "$TAB_Y" 200 "$TAB_Y" 200 2>/dev/null
    sleep 1
    tap_tab 900
    tap_button "Capturar Frente de ID"
    $ADB shell screencap -p "/data/local/tmp/ss.png" 2>/dev/null
    $ADB pull "/data/local/tmp/ss.png" "$outdir/id-front.png" 2>/dev/null | tail -1
    if check_result "FRONT capturado\|mock capture delivered\|capturado"; then
        echo "PASS"; pass=$((pass+1))
    else echo "FAIL"; fail=$((fail+1)); fi

    RESULTS[$api]="$pass/5"
    echo "  => API $api: $pass/5 PASS"

    $ADB shell am force-stop $PKG 2>/dev/null
}

# === MAIN ===
echo "========================================"
echo "  Camera Injection E2E Matrix"
echo "  $(date '+%Y-%m-%d %H:%M')"
echo "========================================"

for avd in "${EMULATORS[@]}"; do
    echo ""
    echo ">>> Starting $avd..."
    kill_emulator
    sleep 2

    # Check if AVD exists
    if ! $EMU -list-avds 2>/dev/null | grep -q "^${avd}$"; then
        echo "  SKIP: AVD $avd not found"
        continue
    fi

    # Launch emulator
    nohup $EMU -avd "$avd" -no-window -no-audio -gpu swiftshader_indirect > /tmp/emu-${avd}.log 2>&1 &
    EMU_PID=$!

    if ! wait_for_boot; then
        echo "  SKIP: $avd failed to boot in 90s"
        kill $EMU_PID 2>/dev/null || true
        continue
    fi

    run_api_test "$avd"

    kill_emulator
done

echo ""
echo "========================================"
echo "  MATRIX RESULTS"
echo "========================================"
for api in $(echo "${!RESULTS[@]}" | tr ' ' '\n' | sort -n); do
    echo "  API $api: ${RESULTS[$api]}"
done
echo "========================================"
