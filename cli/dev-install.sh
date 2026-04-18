#!/usr/bin/env bash
# AutoPilot dev-install — build + install binaries to ~/bin atomically (#69)
#
# Usage:
#   ./cli/dev-install.sh             # debug build
#   ./cli/dev-install.sh --release   # release build
#   ./cli/dev-install.sh --editor    # also refresh editor binaries via setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="debug"
REFRESH_EDITOR=0

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --editor) REFRESH_EDITOR=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"

cd "$SCRIPT_DIR"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BUILD_DIR=".build/$CONFIG"

# Verify all binaries exist (autopilotd is needed by `auto daemon start`)
for bin in auto auto-android autopilotd; do
  if [ ! -f "$BUILD_DIR/$bin" ]; then
    echo "✗ Build did not produce $BUILD_DIR/$bin"
    exit 1
  fi
done

# Atomic install: copy to .new then mv (avoids racing readers)
for bin in auto auto-android autopilotd; do
  cp "$BUILD_DIR/$bin" "$BIN_DIR/$bin.new"
  chmod +x "$BIN_DIR/$bin.new"
  mv "$BIN_DIR/$bin.new" "$BIN_DIR/$bin"
  size=$(stat -f%z "$BIN_DIR/$bin" 2>/dev/null || stat -c%s "$BIN_DIR/$bin")
  echo "✓ $BIN_DIR/$bin ($size bytes, $CONFIG)"
done

# Optional: refresh editor binaries (lightweight, no npm reinstall)
if [ "$REFRESH_EDITOR" -eq 1 ]; then
  REFRESH="$SCRIPT_DIR/../editor/refresh-binaries.sh"
  if [ -x "$REFRESH" ]; then
    echo ""
    if [ "$CONFIG" = "release" ]; then
      "$REFRESH" --release
    else
      "$REFRESH"
    fi
  else
    echo "⚠ editor/refresh-binaries.sh not found, skipping editor refresh"
  fi
fi

echo ""
echo "✓ Done. Verify with: auto --help && auto-android --help"
