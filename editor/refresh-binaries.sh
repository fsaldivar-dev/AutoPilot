#!/usr/bin/env bash
# AutoPilot Composer — Refresh CLI binaries into the Tauri bundle.
#
# Copies cli/.build/{debug,release} binaries to:
#   1. <worktree>/{auto,auto-android}  (tauri dev — resolved via cwd)
#   2. editor/src-tauri/binaries/auto-<triple>  (tauri build — externalBin)
#
# For release mode on macOS we try to build a universal binary via lipo, so
# the same .app runs on both arm64 and x86_64 without a separate build.
#
# Usage:
#   ./editor/refresh-binaries.sh             # debug build, host arch
#   ./editor/refresh-binaries.sh --release   # release build, host arch
#   ./editor/refresh-binaries.sh --universal # release universal (lipo merge)

set -euo pipefail

CONFIG="debug"
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --universal) CONFIG="release"; UNIVERSAL=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# *//'; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/cli/.build/$CONFIG"
BINARIES="$SCRIPT_DIR/src-tauri/binaries"

mkdir -p "$BINARIES"

build_universal() {
  local name="$1"
  local out="$BINARIES/${name}-universal-apple-darwin"
  local arm64="$ROOT_DIR/cli/.build/arm64-apple-macosx/release/${name}"
  local x64="$ROOT_DIR/cli/.build/x86_64-apple-macosx/release/${name}"
  if [ -f "$arm64" ] && [ -f "$x64" ]; then
    lipo -create "$arm64" "$x64" -output "$out"
    chmod +x "$out"
    cp "$out" "$BINARIES/${name}-aarch64-apple-darwin"
    cp "$out" "$BINARIES/${name}-x86_64-apple-darwin"
    cp "$out" "$ROOT_DIR/${name}"
    echo "✓ Universal binary for $name → aarch64 + x86_64 bundle slots"
  else
    echo "✗ Can't build universal $name — run: swift build -c release --arch arm64 --arch x86_64"
    return 1
  fi
}

copy_single_arch() {
  local name="$1"
  if [ ! -f "$BUILD_DIR/$name" ]; then
    echo "✗ $name not found in $BUILD_DIR"
    echo "  Run first: cd cli && swift build${CONFIG:+ -c $CONFIG}"
    exit 1
  fi
  cp "$BUILD_DIR/$name" "$ROOT_DIR/$name"
  chmod +x "$ROOT_DIR/$name"
  local target
  target=$(rustc -vV 2>/dev/null | grep "host:" | awk '{print $2}')
  target=${target:-aarch64-apple-darwin}
  cp "$BUILD_DIR/$name" "$BINARIES/${name}-${target}"
  chmod +x "$BINARIES/${name}-${target}"
  echo "✓ $name → $ROOT_DIR and $BINARIES/${name}-${target}"
}

if [ "$UNIVERSAL" -eq 1 ]; then
  build_universal auto
  build_universal auto-android
else
  copy_single_arch auto
  copy_single_arch auto-android
fi

echo ""
echo "✓ Editor binaries refreshed ($CONFIG build$( [ "$UNIVERSAL" -eq 1 ] && echo ' · universal' ))"
