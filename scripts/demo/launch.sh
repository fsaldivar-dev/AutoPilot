#!/usr/bin/env bash
#
# launch.sh — Arranca el demo con Terminal + Simulator lado a lado
#
# Requisitos:
#   1. Simulator.app abierto con un iPhone booted (xcrun simctl list devices booted)
#   2. autopilotd corriendo (./scripts/demo/start-daemon.sh start) — opcional para XCUI
#
# Uso:
#   ./scripts/demo/launch.sh         # iOS + Android con typewriter
#   ./scripts/demo/launch.sh ios     # solo iOS
#   ./scripts/demo/launch.sh --fast  # modo rápido

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Whitelist allowed args (prevents AppleScript injection below)
DEMO_ARGS=""
for arg in "$@"; do
  case "$arg" in
    ios|android|--fast)
      DEMO_ARGS="$DEMO_ARGS $arg"
      ;;
    *)
      echo "Ignoring unknown argument: $arg"
      ;;
  esac
done
DEMO_ARGS="${DEMO_ARGS# }"

# ─── Pre-flight ──────────────────────────────────────────────

echo "▶ Verificando Simulator..."
if ! xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
  echo "✗ No hay simulador booted"
  echo "  Abrí Simulator.app y booteá un iPhone, o corré:"
  echo "    xcrun simctl boot <UDID>"
  exit 1
fi
echo "  ✓ $(xcrun simctl list devices booted | grep Booted | head -1 | tr -s ' ')"

# Launch Simulator.app to make sure its window is visible
open -a Simulator
sleep 2

# ─── Position Simulator ──────────────────────────────────────

echo "▶ Acomodando Simulator a la derecha..."
osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Simulator" to activate
delay 1

-- Get the visible screen frame of the main display
tell application "Finder"
    set screenBounds to bounds of window of desktop
end tell
set screenX to item 1 of screenBounds
set screenY to item 2 of screenBounds
set screenW to (item 3 of screenBounds) - screenX
set screenH to (item 4 of screenBounds) - screenY

-- Make Simulator take up the RIGHT ~600px
set simW to 600
if simW > (screenW / 2) then
    set simW to screenW / 2
end if

tell application "System Events"
    tell process "Simulator"
        repeat 10 times
            if (count of windows) > 0 then exit repeat
            delay 0.5
        end repeat
        if (count of windows) > 0 then
            set position of window 1 to {screenW - simW, screenY + 30}
            set size of window 1 to {simW, screenH - 40}
        end if
    end tell
end tell
APPLESCRIPT

sleep 1

# ─── Open Terminal with demo ─────────────────────────────────

echo "▶ Abriendo Terminal con el demo..."
# Use a wrapper file to avoid AppleScript string escaping
LAUNCHER="/tmp/autopilot-demo-launcher-$$.sh"
cat > "$LAUNCHER" <<EOF
#!/bin/zsh
cd "$REPO_ROOT"
./scripts/demo/demo-explorea.sh $DEMO_ARGS
echo ""
echo "Demo terminado. Podés cerrar esta ventana."
EOF
chmod +x "$LAUNCHER"

osascript <<APPLESCRIPT 2>/dev/null
tell application "Terminal"
    activate
    do script "$LAUNCHER"
    delay 0.5
end tell

tell application "Finder"
    set screenBounds to bounds of window of desktop
end tell
set screenX to item 1 of screenBounds
set screenY to item 2 of screenBounds
set screenW to (item 3 of screenBounds) - screenX
set screenH to (item 4 of screenBounds) - screenY

set simW to 600
if simW > (screenW / 2) then set simW to screenW / 2
set termW to screenW - simW - 10

tell application "System Events"
    tell process "Terminal"
        if (count of windows) > 0 then
            set position of window 1 to {screenX, screenY + 30}
            set size of window 1 to {termW, screenH - 40}
        end if
    end tell
end tell
APPLESCRIPT

echo ""
echo "✓ Demo corriendo. Deberías ver:"
echo "    ← Terminal con comandos tipeando"
echo "    → Simulator con iPhone interactuando"
echo ""
echo "  Si Simulator sigue tapado o no se ve:"
echo "    1. Cmd+Tab hasta Simulator"
echo "    2. Arrastralo a la derecha manualmente"
echo ""
echo "  Si la primera vez pide permisos de Accessibility:"
echo "    System Settings > Privacy & Security > Accessibility"
echo "    → permitir: Terminal, osascript"
