#!/usr/bin/env bash
#
# start-daemon.sh — Arranca autopilotd con el runner xctest listo para demo
#
# El daemon vive en background y mantiene el runner xctest activo.
# Corrér ANTES de demo-explorea.sh para que la escalación a XCUI funcione.
#
# Uso:
#   ./scripts/demo/start-daemon.sh              # arrancar
#   ./scripts/demo/start-daemon.sh stop         # parar
#   ./scripts/demo/start-daemon.sh status       # ver estado
#   ./scripts/demo/start-daemon.sh logs         # seguir log

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

AUTOPILOTD="$REPO_ROOT/cli/.build/debug/autopilotd"
DAEMON_LOG="$REPO_ROOT/scripts/demo/evidence/daemon.log"
mkdir -p "$(dirname "$DAEMON_LOG")"

# Pick the first booted simulator automatically
UDID=$(xcrun simctl list devices booted -j 2>/dev/null | \
  /usr/bin/awk 'match($0,/"udid" *: *"[^"]*"/){print substr($0,RSTART+10,RLENGTH-11); exit}')

if [ -z "$UDID" ]; then
  echo "✗ no booted simulator. Arrancá uno con: open -a Simulator"
  exit 1
fi

# Find the xctestrun from Xcode DerivedData (built by the UITests target)
XCTESTRUN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "*.xctestrun" \
  -path "*/Build/Products/*" 2>/dev/null | grep -i "Test_Automatitacion" | head -1)

cmd="${1:-start}"

case "$cmd" in
  start)
    echo "▶ Arranca autopilotd"
    echo "  UDID:      $UDID"
    echo "  xctestrun: ${XCTESTRUN:-<no encontrado — compilá Demo/iOS/Test Automatitacion primero>}"
    echo "  log:       $DAEMON_LOG"

    if [ ! -f "$AUTOPILOTD" ]; then
      echo "✗ $AUTOPILOTD no existe. Corré: cd cli && swift build"
      exit 1
    fi

    if [ -z "$XCTESTRUN" ]; then
      echo ""
      echo "Para generar el xctestrun, abre Xcode y hace Product > Build-for-Testing"
      echo "en el esquema 'Test Automatitacion', o:"
      echo ""
      echo "  cd 'Demo/iOS/Test Automatitacion'"
      echo "  xcodebuild build-for-testing \\"
      echo "    -project 'Test Automatitacion.xcodeproj' \\"
      echo "    -scheme 'Test Automatitacion' \\"
      echo "    -destination 'platform=iOS Simulator,id=$UDID'"
      exit 1
    fi

    # Stop if already running
    "$AUTOPILOTD" stop --udid "$UDID" 2>/dev/null | grep -v "^no daemon"

    # --timeout 0 = runner never shuts down while daemon is up.
    # Pagás cold boot UNA SOLA VEZ (en el warm-up de abajo) y después warm siempre.
    AUTOPILOT_RUNNER_XCTESTRUN="$XCTESTRUN" \
    AUTOPILOT_RUNNER_TEST_ID="Test AutomatitacionUITests/AutoPilotRunnerTests/testServe" \
      "$AUTOPILOTD" start --udid "$UDID" --timeout 0 \
      > "$DAEMON_LOG" 2>&1 &

    sleep 2
    echo ""
    "$AUTOPILOTD" status --udid "$UDID"
    echo ""

    # Pre-warm: triggerea el cold boot del runner AHORA (mientras vos tomás café)
    # para que la primera llamada real de auto tree deep sea warm.
    echo "▶ Pre-warming runner XCTest (~30-45s UNA SOLA VEZ)..."
    AUTO_BIN="$REPO_ROOT/cli/.build/debug/auto"
    START_WARM=$(date +%s)
    if AUTO_BRIDGE=xcui "$AUTO_BIN" tree > /dev/null 2>&1; then
      ELAPSED=$(( $(date +%s) - START_WARM ))
      echo "✓ Runner warmed up en ${ELAPSED}s — ya listo para queries sub-segundo"
    else
      echo "⚠ Runner warm-up falló — el primer auto tree deep pagará el cold boot"
    fi
    echo ""
    echo "✓ Daemon + runner listos"
    echo "  Probá: auto tree deep  (warm = ~1.5s)"
    ;;

  stop)
    "$AUTOPILOTD" stop --udid "$UDID"
    ;;

  status)
    "$AUTOPILOTD" status --udid "$UDID"
    ;;

  logs)
    tail -f "$DAEMON_LOG"
    ;;

  *)
    echo "Uso: $0 [start|stop|status|logs]"
    exit 1
    ;;
esac
