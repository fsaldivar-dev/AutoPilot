#!/usr/bin/env bash
#
# demo-explorea.sh — Live demo de AutoPilot contra la app Explorea
#
# Simula que todos los comandos se escriben en consola en vivo, corre contra:
#   - iOS: Test Automatitacion (bundle dev.autopilot.test.Explorea)
#   - Android: TestAutomatitacion (mismo bundle, APK en emulador)
#
# El flujo iOS EXPLÍCITAMENTE muestra el caso que rompía antes:
# tap "Guardar" en el NavBar SwiftUI de NewEntryView, que con SimulatorBridge
# daba "element not found" y ahora con HybridBridge escala automáticamente
# al XCUIBridge y funciona.
#
# Uso:
#   ./scripts/demo/demo-explorea.sh            # iOS + Android
#   ./scripts/demo/demo-explorea.sh ios        # solo iOS
#   ./scripts/demo/demo-explorea.sh android    # solo Android
#   ./scripts/demo/demo-explorea.sh --fast     # sin pausas dramáticas

set -u  # no -e — queremos ver los fallos esperados

# ────────────────────────────────────────────────────────
#  Config
# ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

AUTO="$REPO_ROOT/cli/.build/debug/auto"
AUTO_ANDROID="$REPO_ROOT/cli/.build/debug/auto-android"
AUTOPILOTD="$REPO_ROOT/cli/.build/debug/autopilotd"

BUNDLE_IOS="shajaru.Test-Automatitacion"        # bundle id real de Explorea iOS
PKG_ANDROID="dev.autopilot.test.Explorea"

EVIDENCE_DIR="$REPO_ROOT/scripts/demo/evidence"
LOG_FILE="$EVIDENCE_DIR/demo.log"
mkdir -p "$EVIDENCE_DIR"
: > "$LOG_FILE"

FAST_MODE=0
PLATFORMS="ios android"
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=1 ;;
    ios) PLATFORMS="ios" ;;
    android) PLATFORMS="android" ;;
    *) ;;
  esac
done

# Colors
C_RESET='\033[0m'
C_CYAN='\033[0;36m'
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_BOLD='\033[1m'
C_DIM='\033[2m'

# ────────────────────────────────────────────────────────
#  Primitives — typewriter + logging
# ────────────────────────────────────────────────────────

pause() {
  local secs="${1:-1}"
  [ $FAST_MODE -eq 1 ] && return
  sleep "$secs"
}

# Bring Simulator.app to the front so user can see the interactions
activate_simulator() {
  osascript -e 'tell application "Simulator" to activate' > /dev/null 2>&1
}

# Position Simulator on the right half of the screen and Terminal on the left
# so both are visible side-by-side during the demo.
arrange_windows() {
  osascript <<'APPLESCRIPT' > /dev/null 2>&1
tell application "Finder"
    set screenSize to bounds of window of desktop
    set screenW to item 3 of screenSize
    set screenH to item 4 of screenSize
end tell

-- Simulator on the right half
tell application "System Events"
    tell process "Simulator"
        if exists window 1 then
            set position of window 1 to {screenW / 2, 0}
            set size of window 1 to {screenW / 2, screenH}
        end if
    end tell
end tell

-- Terminal on the left half
tell application "System Events"
    tell process "Terminal"
        if exists window 1 then
            set position of window 1 to {0, 0}
            set size of window 1 to {screenW / 2, screenH}
        end if
    end tell
end tell
APPLESCRIPT
}

type_line() {
  # Typewriter effect for a command line. Fast mode skips it.
  local text="$1"
  if [ $FAST_MODE -eq 1 ]; then
    printf "%b\n" "$text"
    return
  fi
  local i=0
  while [ $i -lt ${#text} ]; do
    printf "%s" "${text:$i:1}"
    sleep 0.015
    i=$((i+1))
  done
  printf "\n"
}

banner() {
  local text="$1"
  local color="${2:-$C_CYAN}"
  echo ""
  printf "%b%b" "$color" "$C_BOLD"
  printf "╔"
  printf "═%.0s" $(seq 1 $((${#text}+2)))
  printf "╗\n"
  printf "║ %s ║\n" "$text"
  printf "╚"
  printf "═%.0s" $(seq 1 $((${#text}+2)))
  printf "╝"
  printf "%b\n" "$C_RESET"
}

step() {
  echo ""
  printf "%b%b▶ %s%b\n" "$C_YELLOW" "$C_BOLD" "$1" "$C_RESET"
}

narrate() {
  printf "%b  %s%b\n" "$C_DIM" "$1" "$C_RESET"
}

# Run a command visible + timed + logged
run() {
  local shown="$1"; shift
  local expect_fail=0
  if [ "$1" = "--expect-fail" ]; then expect_fail=1; shift; fi

  printf "%b%b$%b " "$C_BLUE" "$C_BOLD" "$C_RESET"
  type_line "$shown"
  echo "[CMD] $shown" >> "$LOG_FILE"

  local start=$(($(date +%s%N)/1000000))
  local output
  output=$("$@" 2>&1)
  local exit_code=$?
  local elapsed=$(($(date +%s%N)/1000000 - start))

  echo "$output" >> "$LOG_FILE"
  echo "[EXIT=$exit_code ELAPSED=${elapsed}ms]" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  # Print first N lines of output, indented
  if [ -n "$output" ]; then
    echo "$output" | head -8 | while IFS= read -r line; do
      printf "  %b│%b %s\n" "$C_DIM" "$C_RESET" "$line"
    done
    local total_lines=$(echo "$output" | wc -l | tr -d ' ')
    if [ "$total_lines" -gt 8 ]; then
      printf "  %b│ ... %s more line(s)%b\n" "$C_DIM" "$((total_lines - 8))" "$C_RESET"
    fi
  fi

  if [ $exit_code -eq 0 ]; then
    printf "  %b✓ ok%b %b(%sms)%b\n" "$C_GREEN" "$C_RESET" "$C_DIM" "$elapsed" "$C_RESET"
  else
    if [ $expect_fail -eq 1 ]; then
      printf "  %b⚠ falló (esperado)%b %b(%sms)%b\n" "$C_MAGENTA" "$C_RESET" "$C_DIM" "$elapsed" "$C_RESET"
    else
      printf "  %b✗ falló%b %b(%sms)%b\n" "$C_RED" "$C_RESET" "$C_DIM" "$elapsed" "$C_RESET"
    fi
  fi

  pause 0.6
  return $exit_code
}

# ────────────────────────────────────────────────────────
#  Pre-flight
# ────────────────────────────────────────────────────────

preflight() {
  banner "PRE-FLIGHT: verificando binarios y ambientes" "$C_MAGENTA"

  for bin in "$AUTO" "$AUTO_ANDROID" "$AUTOPILOTD"; do
    if [ ! -f "$bin" ]; then
      printf "%b✗ %s no existe. Ejecutá: cd cli && swift build%b\n" "$C_RED" "$bin" "$C_RESET"
      exit 1
    fi
  done
  printf "%b✓ binarios OK%b  auto · auto-android · autopilotd\n" "$C_GREEN" "$C_RESET"

  if [[ "$PLATFORMS" == *ios* ]]; then
    if ! xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
      printf "%b✗ sin simulador booted. Abrí Simulator.app y arrancá un iPhone.%b\n" "$C_RED" "$C_RESET"
      exit 1
    fi
    local sim_info
    sim_info=$(xcrun simctl list devices booted | grep Booted | head -1 | tr -s ' ')
    printf "%b✓ iOS Sim%b %s\n" "$C_GREEN" "$C_RESET" "$sim_info"
  fi

  if [[ "$PLATFORMS" == *android* ]]; then
    if ! adb devices | grep -q "device$"; then
      printf "%b⚠ sin emulador Android — se omite Android%b\n" "$C_YELLOW" "$C_RESET"
      PLATFORMS="${PLATFORMS/android/}"
    else
      printf "%b✓ Android emu%b %s\n" "$C_GREEN" "$C_RESET" "$(adb devices | grep 'device$' | head -1)"
    fi
  fi

  # Detect if autopilotd is running (for the XCUI escalation demo)
  DAEMON_READY=0
  if [[ "$PLATFORMS" == *ios* ]]; then
    local sim_udid=$(xcrun simctl list devices booted -j 2>/dev/null | \
      /usr/bin/awk 'match($0,/"udid" *: *"[^"]*"/){print substr($0,RSTART+10,RLENGTH-11); exit}')
    if [ -n "$sim_udid" ] && "$AUTOPILOTD" status --udid "$sim_udid" 2>&1 | grep -q "running"; then
      printf "%b✓ autopilotd%b corriendo — " "$C_GREEN" "$C_RESET"

      # Check if runner is already booted — if not, warm it up now so the
      # demo's "Guardar" tap doesn't time out waiting for cold boot (~45s)
      local runner_state
      runner_state=$("$AUTOPILOTD" status --udid "$sim_udid" 2>&1 | grep -oE '"runner":"[a-z_]+"' | cut -d'"' -f4)
      if [ "$runner_state" = "ready" ]; then
        printf "runner ready ✓\n"
        DAEMON_READY=1
      else
        printf "%brunner no booted — warming up (puede tardar ~45s)...%b\n" "$C_YELLOW" "$C_RESET"
        # Trigger cold boot by making one XCUI tree call with long timeout
        if AUTO_BRIDGE=xcui "$AUTO" tree > /dev/null 2>&1; then
          printf "%b✓ runner XCTest warmed up%b\n" "$C_GREEN" "$C_RESET"
          DAEMON_READY=1
        else
          printf "%b⚠ runner warmup falló — seguimos sin escalación XCUI%b\n" "$C_YELLOW" "$C_RESET"
        fi
      fi
    else
      printf "%b⚠ autopilotd NO activo%b — el step 'Guardar' mostrará el fallo esperado\n" "$C_YELLOW" "$C_RESET"
      printf "%b   Para ver la escalación: ./scripts/demo/start-daemon.sh start%b\n" "$C_DIM" "$C_RESET"
    fi
  fi

  echo ""
  printf "%bEvidencia se guarda en:%b %s\n" "$C_DIM" "$C_RESET" "$EVIDENCE_DIR"
  printf "%bLog completo:%b %s\n" "$C_DIM" "$C_RESET" "$LOG_FILE"
}

DAEMON_READY=0

# ────────────────────────────────────────────────────────
#  iOS demo
# ────────────────────────────────────────────────────────

demo_ios() {
  banner "iOS — Settings app con HybridBridge (fast + XCUI fallback)"

  narrate "Settings es el banco de pruebas ideal:"
  narrate "  - sin auth (0 fricción)"
  narrate "  - tiene NavigationBar con StaticText como title"
  narrate "  - al navegar a un detalle, aparece un botón 'back' en la NavBar"
  narrate ""
  narrate "El test clave: XCUIBridge ve 'NavigationBar id=...' como elemento"
  narrate "queryable con children, mientras SimulatorBridge solo ve AXGroup."
  narrate ""
  narrate "▶ Acomodando ventanas: Terminal ← → Simulator"
  pause 1

  # Put Terminal on the left half and Simulator on the right half
  activate_simulator
  arrange_windows
  pause 2

  export AUTO_BRIDGE=simulator  # fast-path para todo menos el tree comparison

  step "1/6 — Terminate + launch Settings (fresh state)"
  narrate "Mirá el Simulator: Settings se va a cerrar y abrir de nuevo"
  activate_simulator
  run "auto terminate com.apple.Preferences" \
    "$AUTO" terminate "com.apple.Preferences" || true
  pause 2
  run "auto launch com.apple.Preferences" \
    "$AUTO" launch "com.apple.Preferences"
  activate_simulator
  # Wait for Settings root to be indexable before screenshot
  sleep 3

  step "2/6 — Screenshot de la pantalla principal"
  activate_simulator
  run "auto screenshot 01-settings-root.png" \
    "$AUTO" screenshot "$EVIDENCE_DIR/01-settings-root.png"

  step "3/6 — Comparación de árboles: SimulatorBridge vs XCUIBridge"
  narrate "Miramos qué ve cada bridge del NavigationBar de Settings"
  echo ""
  narrate "→ SimulatorBridge (AX macOS externo):"
  AUTO_BRIDGE=simulator "$AUTO" tree 2>&1 | grep -iE "nav|toolbar|heading" | head -5 | sed 's/^/     /'
  echo ""
  narrate "→ XCUIBridge (XCTest runner dentro del sim):"
  if [ "$DAEMON_READY" = "1" ]; then
    AUTO_BRIDGE=xcui "$AUTO" tree 2>&1 | grep -iE "NavigationBar|Tab|Window" | head -5 | sed 's/^/     /'
  else
    narrate "     (daemon no activo — saltamos)"
  fi
  pause 3

  step "4/6 — Navegar: tap 'General' (fast-path, visible en AX)"
  narrate "Mirá el Simulator: el cursor se mueve y tapea 'General'"
  activate_simulator
  pause 1
  run "auto tap 'General'" \
    "$AUTO" tap "General"
  pause 3
  activate_simulator
  run "auto screenshot 02-settings-general.png" \
    "$AUTO" screenshot "$EVIDENCE_DIR/02-settings-general.png"

  # ──────────── THE MONEY SHOT ────────────
  step "5/6 — Tap en el 'back button' de la NavBar (el caso crítico)"
  narrate ""
  narrate "Estamos en Settings→General. Hay un '< Configuración' en la NavBar"
  narrate "que en apps SwiftUI con iOS 26 a veces NO se expone a AX macOS."
  narrate ""
  narrate "Antes: SimulatorBridge → 'element not found'"
  narrate "Ahora: HybridBridge → fast falla → escala a XCUI → tap OK"
  narrate ""
  pause 2

  narrate "1) Intento con SimulatorBridge explícito:"
  activate_simulator
  pause 1
  run "AUTO_BRIDGE=simulator auto tap 'Configuración'" --expect-fail \
    env AUTO_BRIDGE=simulator "$AUTO" tap "Configuración"
  pause 2

  if [ "$DAEMON_READY" = "1" ]; then
    narrate ""
    narrate "2) Ahora con HybridBridge (mirá el Simulator — va a volver al root):"
    activate_simulator
    pause 1
    unset AUTO_BRIDGE
    run "auto tap 'Configuración'   # hybrid: fast→deep" \
      "$AUTO" tap "Configuración"
    pause 3
    activate_simulator
    run "auto screenshot 03-back-to-root.png" \
      "$AUTO" screenshot "$EVIDENCE_DIR/03-back-to-root.png"
  else
    narrate "   ⚠ daemon no activo — saltamos escalación"
  fi

  step "6/6 — Benchmark: latencia de 'tap General' en los 3 bridges"
  narrate "El objetivo: mostrar que HybridBridge no penaliza perf vs Simulator"
  narrate "Cada iteración termina+launch para empezar limpio"

  echo ""
  echo "     run | simulator | hybrid  | xcui (warm)"
  echo "     ─── ─────────── ───────── ─────────────"

  bench_tap() {
    local bridge_env="$1"
    "$AUTO" terminate "com.apple.Preferences" > /dev/null 2>&1
    sleep 1.5
    "$AUTO" launch "com.apple.Preferences" > /dev/null 2>&1
    # Bring Simulator.app to foreground so AX macOS can see it
    osascript -e 'tell application "Simulator" to activate' > /dev/null 2>&1
    # Give Settings enough time to fully render — timing critical on cold start
    sleep 4
    local out
    if [ -z "$bridge_env" ]; then
      out=$("$AUTO" tap "General" 2>&1)
    else
      # For XCUI, also ensure runner re-attaches to the newly-launched app
      if [ "$bridge_env" = "xcui" ]; then
        env AUTO_BRIDGE=xcui "$AUTO" launch com.apple.Preferences > /dev/null 2>&1
        sleep 1
      fi
      out=$(env AUTO_BRIDGE="$bridge_env" "$AUTO" tap "General" 2>&1)
    fi
    echo "$out" | grep -oE '\([0-9]+ms\)' | head -1 | tr -d '()'
  }

  for i in 1 2 3; do
    sim=$(bench_tap simulator)
    hyb=$(bench_tap "")
    if [ "$DAEMON_READY" = "1" ]; then
      xcui=$(bench_tap xcui)
    else
      xcui="-"
    fi
    printf "     %d   | %-9s | %-7s | %s\n" "$i" "${sim:-FAIL}" "${hyb:-FAIL}" "${xcui:-FAIL}"
  done

  banner "iOS demo terminado" "$C_GREEN"
}

# ────────────────────────────────────────────────────────
#  Android demo
# ────────────────────────────────────────────────────────

demo_android() {
  banner "Android — Explorea con AgentBridge"

  narrate "En Android no hay 'híbrido' porque AgentBridge usa UiAutomation"
  narrate "dentro del device y ya ve todo. Demostramos el mismo flujo:"
  narrate "launch → auth → crear entrada → guardar → screenshot."
  pause 2

  step "1/6 — Verificar agente AgentBridge (socket activo)"
  run "auto-android ping" \
    "$AUTO_ANDROID" ping

  step "2/6 — Clear state + launch Explorea"
  run "auto-android clearState $PKG_ANDROID" \
    "$AUTO_ANDROID" clearState "$PKG_ANDROID"
  pause 1
  run "auto-android launch $PKG_ANDROID" \
    "$AUTO_ANDROID" launch "$PKG_ANDROID"
  # Compose apps need a bit more time to render
  sleep 5

  step "3/6 — Screenshot inicial + tree (qué vemos)"
  run "auto-android screenshot 01-android-initial.png" \
    "$AUTO_ANDROID" screenshot "$EVIDENCE_DIR/01-android-initial.png"

  step "4/6 — Navegar si hay AuthView (tap 'Continuar' o similar)"
  # Try common Android entry buttons — don't fail hard
  run "auto-android tap 'Continuar'" "$AUTO_ANDROID" tap "Continuar" || \
  run "auto-android tap 'Empezar'" "$AUTO_ANDROID" tap "Empezar" || \
  narrate "Pantalla principal directa — ok"
  pause 2

  step "5/6 — Explorar tree + tap elemento visible"
  run "auto-android tree" \
    "$AUTO_ANDROID" tree
  pause 1

  step "6/6 — Screenshot final"
  run "auto-android screenshot 02-android-final.png" \
    "$AUTO_ANDROID" screenshot "$EVIDENCE_DIR/02-android-final.png"

  banner "Android demo terminado" "$C_GREEN"
}

# ────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────

main() {
  clear
  banner "AutoPilot DEMO — Explorea (iOS + Android)" "$C_MAGENTA"
  echo ""
  narrate "Este demo corre contra la app Explorea (diario de viajes SwiftUI"
  narrate "para iOS / Jetpack Compose para Android), ejecutando comandos auto"
  narrate "y auto-android en vivo, guardando screenshots y logs en:"
  narrate "  $EVIDENCE_DIR"
  narrate ""
  narrate "El foco iOS es el botón 'Guardar' en NavigationBar SwiftUI — el"
  narrate "primer elemento que SimulatorBridge nunca pudo ver y ahora el"
  narrate "HybridBridge resuelve automáticamente vía XCUIBridge."
  pause 3

  preflight

  if [[ "$PLATFORMS" == *ios* ]]; then
    demo_ios
    pause 2
  fi

  if [[ "$PLATFORMS" == *android* ]]; then
    demo_android
    pause 2
  fi

  banner "FIN DEL DEMO" "$C_GREEN"
  echo ""
  printf "%bEvidencia generada:%b\n" "$C_BOLD" "$C_RESET"
  ls -lh "$EVIDENCE_DIR" | tail -n +2 | awk '{printf "  %s  %s\n", $5, $NF}'
  echo ""
  printf "%bLog completo:%b %s\n" "$C_BOLD" "$C_RESET" "$LOG_FILE"
}

main "$@"
