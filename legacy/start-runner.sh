#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../runner"
SIMULATOR_NAME="${1:-AutoRunner iPhone 16}"
SOCKET_PATH="/tmp/autoapp.sock"

# Clean up previous socket
rm -f "$SOCKET_PATH"

echo "==================================="
echo " AutoApp Runner"
echo "==================================="
echo "Simulator: $SIMULATOR_NAME"
echo "Socket:    $SOCKET_PATH"
echo ""

# Boot simulator if not already booted
echo "[1/3] Booting simulator..."
xcrun simctl boot "$SIMULATOR_NAME" 2>/dev/null || true

# Open Simulator.app to see it
open -a Simulator

echo "[2/3] Building and launching runner..."
echo "       (this may take a moment on first build)"
echo ""

# Build and run the UI test
xcodebuild test \
    -project "$PROJECT_DIR/AutoRunner.xcodeproj" \
    -scheme "AutoRunnerUITests" \
    -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
    -only-testing:AutoRunnerUITests/RunnerTest/testSocketServer \
    -test-timeouts-enabled NO \
    2>&1 | while IFS= read -r line; do
        # Filter to show only relevant output
        if [[ "$line" == *"[AutoApp]"* ]]; then
            echo "$line"
        elif [[ "$line" == *"error:"* ]]; then
            echo "ERROR: $line"
        elif [[ "$line" == *"Build Succeeded"* ]]; then
            echo "[3/3] Build succeeded, starting socket server..."
        fi
    done
