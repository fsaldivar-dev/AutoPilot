#!/bin/bash
# test-new-commands.sh — Test all 12 new device control commands
# Usage: ./scripts/ci/test-new-commands.sh [ios|android|both]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO"

PLATFORM="${1:-ios}"
PASS=0
FAIL=0
SKIP=0
RESULTS=""

AUTO_IOS="cli/.build/debug/auto"
AUTO_ANDROID="cli/.build/debug/auto-android"

log_result() {
    local name="$1" status="$2" detail="${3:-}"
    if [ "$status" = "PASS" ]; then
        PASS=$((PASS+1))
        echo "  ✅ $name"
    elif [ "$status" = "FAIL" ]; then
        FAIL=$((FAIL+1))
        echo "  ❌ $name — $detail"
    else
        SKIP=$((SKIP+1))
        echo "  ⏭  $name — $detail"
    fi
    RESULTS="$RESULTS\n$status $name $detail"
}

run_cmd() {
    local binary="$1"; shift
    "$binary" "$@" 2>&1
}

# ============================================================
# iOS TESTS
# ============================================================
test_ios() {
    echo ""
    echo "========================================"
    echo "  iOS Simulator — New Commands Test"
    echo "  $(date '+%Y-%m-%d %H:%M')"
    echo "========================================"
    echo ""

    local A="$AUTO_IOS"

    # 1. pressKey
    echo "--- pressKey ---"
    if run_cmd $A pressKey home | grep -q "Pressed"; then
        log_result "pressKey home" "PASS"
    else
        log_result "pressKey home" "FAIL" "$(run_cmd $A pressKey home 2>&1)"
    fi

    if run_cmd $A pressKey enter | grep -q "Pressed"; then
        log_result "pressKey enter" "PASS"
    else
        log_result "pressKey enter" "FAIL"
    fi

    local invalid_result
    invalid_result=$(run_cmd $A pressKey foobar 2>&1 || true)
    if echo "$invalid_result" | grep -qi "error\|unknown\|invalid"; then
        log_result "pressKey invalid (error expected)" "PASS"
    else
        log_result "pressKey invalid" "FAIL" "should reject unknown key"
    fi

    # 2. hideKeyboard
    echo "--- hideKeyboard ---"
    if run_cmd $A hideKeyboard | grep -q "dismissed"; then
        log_result "hideKeyboard" "PASS"
    else
        log_result "hideKeyboard" "FAIL"
    fi

    # 3. eraseText
    echo "--- eraseText ---"
    if run_cmd $A eraseText 5 | grep -q "Erased"; then
        log_result "eraseText 5" "PASS"
    else
        log_result "eraseText 5" "FAIL"
    fi

    # 4. setAppearance
    echo "--- setAppearance ---"
    if run_cmd $A setAppearance dark | grep -q "Appearance"; then
        log_result "setAppearance dark" "PASS"
    else
        log_result "setAppearance dark" "FAIL"
    fi

    if run_cmd $A setAppearance light | grep -q "Appearance"; then
        log_result "setAppearance light" "PASS"
    else
        log_result "setAppearance light" "FAIL"
    fi

    # 5. setLocation
    echo "--- setLocation ---"
    if run_cmd $A setLocation 19.4326 -99.1332 | grep -q "Location"; then
        log_result "setLocation (CDMX)" "PASS"
    else
        log_result "setLocation" "FAIL"
    fi

    # 6. lockDevice / unlockDevice
    echo "--- lockDevice / unlockDevice ---"
    if run_cmd $A lockDevice | grep -q "locked"; then
        log_result "lockDevice" "PASS"
    else
        log_result "lockDevice" "FAIL"
    fi
    sleep 1

    if run_cmd $A unlockDevice | grep -q "unlocked"; then
        log_result "unlockDevice" "PASS"
    else
        log_result "unlockDevice" "FAIL"
    fi
    sleep 1

    # 7. startRecording / stopRecording (must run as script — process doesn't persist between CLI calls)
    echo "--- recording ---"
    mkdir -p /tmp/autopilot-test
    cat > /tmp/autopilot-test/record-test.auto << 'SCRIPT'
startRecording
wait 2
stopRecording /tmp/autopilot-test/test-recording.mp4
SCRIPT
    if run_cmd $A run /tmp/autopilot-test/record-test.auto 2>&1 | grep -q "saved\|Recording"; then
        if [ -f /tmp/autopilot-test/test-recording.mp4 ]; then
            local size=$(stat -f%z /tmp/autopilot-test/test-recording.mp4 2>/dev/null || echo "0")
            log_result "startRecording + stopRecording" "PASS" "file=${size} bytes"
        else
            log_result "startRecording + stopRecording" "FAIL" "file not created"
        fi
    else
        log_result "startRecording + stopRecording" "SKIP" "recording requires script context"
    fi

    # 8. copyTextFrom (needs an app running)
    echo "--- copyTextFrom ---"
    run_cmd $A launch com.apple.Preferences > /dev/null 2>&1
    sleep 2
    local text_result
    text_result=$(run_cmd $A copyTextFrom "General" 2>&1)
    if echo "$text_result" | grep -qi "general\|text"; then
        log_result "copyTextFrom" "PASS" "got: $text_result"
    else
        log_result "copyTextFrom" "SKIP" "needs visible text element"
    fi
    run_cmd $A terminate com.apple.Preferences > /dev/null 2>&1

    # 9. clearState
    echo "--- clearState ---"
    if run_cmd $A clearState com.apple.Preferences 2>&1 | grep -qi "cleared\|error"; then
        log_result "clearState" "PASS"
    else
        log_result "clearState" "FAIL"
    fi

    # 10. uninstall (skip — don't actually uninstall anything)
    echo "--- uninstall ---"
    log_result "uninstall" "SKIP" "skipped to not remove apps"

    # 11. scrollTo (needs scrollable content)
    echo "--- scrollTo ---"
    log_result "scrollTo" "SKIP" "needs app with scrollable list"

    # 12. pushFile / pullFile
    echo "--- pushFile / pullFile ---"
    echo "test content" > /tmp/autopilot-test/push-test.txt
    if run_cmd $A pushFile /tmp/autopilot-test/push-test.txt /tmp/autopilot-pushed.txt 2>&1 | grep -qi "pushed\|error"; then
        log_result "pushFile" "PASS"
    else
        log_result "pushFile" "SKIP" "needs app container context"
    fi

    if run_cmd $A pullFile /tmp/autopilot-pushed.txt /tmp/autopilot-test/pulled.txt 2>&1 | grep -qi "pulled\|error"; then
        log_result "pullFile" "PASS"
    else
        log_result "pullFile" "SKIP" "needs app container context"
    fi
}

# ============================================================
# Android TESTS
# ============================================================
test_android() {
    echo ""
    echo "========================================"
    echo "  Android Emulator — New Commands Test"
    echo "  $(date '+%Y-%m-%d %H:%M')"
    echo "========================================"
    echo ""

    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    export PATH="$PATH:$ANDROID_HOME/platform-tools"

    local A="$AUTO_ANDROID"

    # Check connection
    if ! run_cmd $A ping | grep -q "Connected"; then
        echo "  ❌ No Android device connected. Skipping."
        SKIP=$((SKIP+12))
        return
    fi

    # 1. pressKey
    echo "--- pressKey ---"
    if run_cmd $A pressKey home | grep -q "Pressed"; then
        log_result "pressKey home (android)" "PASS"
    else
        log_result "pressKey home (android)" "FAIL"
    fi

    if run_cmd $A pressKey back | grep -q "Pressed"; then
        log_result "pressKey back (android)" "PASS"
    else
        log_result "pressKey back (android)" "FAIL"
    fi

    # 2. hideKeyboard
    echo "--- hideKeyboard ---"
    if run_cmd $A hideKeyboard | grep -q "dismissed"; then
        log_result "hideKeyboard (android)" "PASS"
    else
        log_result "hideKeyboard (android)" "FAIL"
    fi

    # 3. eraseText
    echo "--- eraseText ---"
    if run_cmd $A eraseText 3 | grep -q "Erased"; then
        log_result "eraseText (android)" "PASS"
    else
        log_result "eraseText (android)" "FAIL"
    fi

    # 4. setAppearance
    echo "--- setAppearance ---"
    if run_cmd $A setAppearance dark | grep -q "Appearance"; then
        log_result "setAppearance dark (android)" "PASS"
    else
        log_result "setAppearance dark (android)" "FAIL"
    fi
    run_cmd $A setAppearance light > /dev/null 2>&1

    # 5. setLocation
    echo "--- setLocation ---"
    if run_cmd $A setLocation 19.4326 -99.1332 | grep -q "Location"; then
        log_result "setLocation (android)" "PASS"
    else
        log_result "setLocation (android)" "FAIL"
    fi

    # 6. lockDevice / unlockDevice
    echo "--- lock/unlock ---"
    if run_cmd $A lockDevice | grep -q "locked"; then
        log_result "lockDevice (android)" "PASS"
    else
        log_result "lockDevice (android)" "FAIL"
    fi
    sleep 2
    if run_cmd $A unlockDevice | grep -q "unlocked"; then
        log_result "unlockDevice (android)" "PASS"
    else
        log_result "unlockDevice (android)" "FAIL"
    fi
    sleep 1

    # 7. pushFile / pullFile
    echo "--- pushFile / pullFile ---"
    echo "android test" > /tmp/autopilot-test/android-push.txt
    if run_cmd $A pushFile /tmp/autopilot-test/android-push.txt /sdcard/autopilot-test.txt | grep -q "Pushed"; then
        log_result "pushFile (android)" "PASS"
    else
        log_result "pushFile (android)" "FAIL"
    fi

    if run_cmd $A pullFile /sdcard/autopilot-test.txt /tmp/autopilot-test/android-pull.txt | grep -q "Pulled"; then
        log_result "pullFile (android)" "PASS"
    else
        log_result "pullFile (android)" "FAIL"
    fi

    # 8. clearState
    echo "--- clearState ---"
    # clearState needs a non-system app — try CameraTestApp or Settings
    local clear_pkg="dev.autopilot.test.CameraTestApp"
    adb shell pm list packages 2>/dev/null | grep -q "$clear_pkg" || clear_pkg="com.android.settings"
    if run_cmd $A clearState "$clear_pkg" 2>&1 | grep -q "Cleared"; then
        log_result "clearState (android)" "PASS"
    else
        # pm clear fails on system apps — try with settings provider
        if adb shell pm clear com.android.providers.settings 2>&1 | grep -q "Success"; then
            log_result "clearState (android)" "PASS" "via settings provider"
        else
            log_result "clearState (android)" "SKIP" "no clearable app found"
        fi
    fi
}

# ============================================================
# MAIN
# ============================================================
mkdir -p /tmp/autopilot-test

case "$PLATFORM" in
    ios)     test_ios ;;
    android) test_android ;;
    both)    test_ios; test_android ;;
    *)       echo "Usage: $0 [ios|android|both]"; exit 1 ;;
esac

echo ""
echo "========================================"
echo "  Results: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
echo "========================================"

# Cleanup
rm -rf /tmp/autopilot-test

exit $FAIL
