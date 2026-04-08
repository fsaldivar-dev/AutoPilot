#!/usr/bin/env bash
# AutoPilot Editor — Refresh binaries (#70)
#
# Copies the current cli/.build binaries into the editor's locations
# (sidecar for tauri dev, externalBin for tauri build) without re-running
# npm install or the full setup.sh.
#
# Usage:
#   ./editor/refresh-binaries.sh             # use debug build
#   ./editor/refresh-binaries.sh --release   # use release build

set -euo pipefail

CONFIG="debug"
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# *//'; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/cli/.build/$CONFIG"

if [ ! -f "$BUILD_DIR/auto" ] || [ ! -f "$BUILD_DIR/auto-android" ]; then
  echo "✗ Binaries not found in $BUILD_DIR"
  echo "  Run first: cd cli && swift build${CONFIG:+ -c $CONFIG}"
  exit 1
fi

# 1. Tauri dev resolves binaries via cwd-relative path (../auto)
cp "$BUILD_DIR/auto" "$ROOT_DIR/auto"
cp "$BUILD_DIR/auto-android" "$ROOT_DIR/auto-android"
echo "✓ Copied to $ROOT_DIR/{auto,auto-android} (tauri dev)"

# 2. Tauri build uses externalBin with target triple suffix
TARGET=$(rustc -vV 2>/dev/null | grep "host:" | awk '{print $2}')
TARGET=${TARGET:-aarch64-apple-darwin}
mkdir -p "$SCRIPT_DIR/src-tauri/binaries"
cp "$BUILD_DIR/auto" "$SCRIPT_DIR/src-tauri/binaries/auto-${TARGET}"
cp "$BUILD_DIR/auto-android" "$SCRIPT_DIR/src-tauri/binaries/auto-android-${TARGET}"
echo "✓ Copied to $SCRIPT_DIR/src-tauri/binaries/auto{,-android}-$TARGET (tauri build)"

echo ""
echo "✓ Editor binaries refreshed ($CONFIG build)"
