#!/usr/bin/env bash
# benchmark.sh — Benchmark comparativo de bridges Android (#62)
#
# Mide latencia (p50/p95) de operaciones clave contra la demo app Explorea
# (dev.autopilot.test.Explorea) con tres backends:
#
#   1. AgentBridge      — auto-android default (socket TCP al agente on-device)
#   2. AdbLegacyBridge  — auto-android --legacy (adb shell + uiautomator dump).
#                         Requiere `agent stop` primero: Android solo permite
#                         un cliente UiAutomation a la vez (ver #135).
#   3. Maestro          — si esta instalado en ~/.maestro/bin/maestro. Se
#                         generan flows YAML minimos equivalentes. El driver
#                         de Maestro tambien usa UiAutomator, asi que corre
#                         con el agente detenido.
#
# Operaciones: ping, tree, tap (semantico, label "Explorea"), screenshot,
# swipe. Cada invocacion es proceso frio (CLI completo), igual para todas las
# herramientas — es la latencia real que ve un usuario por comando.
#
# Uso:
#   ./scripts/benchmark.sh                  # corrida completa (~8-12 min)
#   ITERATIONS=5 ./scripts/benchmark.sh     # menos iteraciones
#   ./scripts/benchmark.sh --skip-maestro   # solo AgentBridge vs AdbLegacyBridge
#   ./scripts/benchmark.sh --dry-run        # valida el pipeline sin device
#
# Salida:
#   - Tabla markdown en stdout
#   - docs/benchmark/RESULTS-<fecha>.md
#   - Datos crudos (jsonl) en $RESULTS_DIR (temporal por default)
#
# Requisitos: emulador/device Android corriendo (adb devices), Explorea
# instalada (auto-android setup), binario auto-android compilado.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config ──────────────────────────────────────────────────────────────
ITERATIONS="${ITERATIONS:-10}"          # corridas medidas por operacion
WARMUP_RUNS=1                           # descartadas
PKG="dev.autopilot.test.Explorea"
ACTIVITY="$PKG/.MainActivity"
MAESTRO_BIN="${MAESTRO_BIN:-$HOME/.maestro/bin/maestro}"
RESULTS_DIR="${RESULTS_DIR:-}"
DOCS_DIR="$PROJECT_ROOT/docs/benchmark"
DRY_RUN=0
SKIP_MAESTRO=0
SKIP_LEGACY=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1 ;;
    --skip-maestro)  SKIP_MAESTRO=1 ;;
    --skip-legacy)   SKIP_LEGACY=1 ;;
    --iterations)    shift; ITERATIONS="$1" ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Flag desconocido: $1 (ver --help)"; exit 1 ;;
  esac
  shift
done

# ── Binario auto-android ────────────────────────────────────────────────
if [ -n "${AUTO_ANDROID_BIN:-}" ]; then
  BIN="$AUTO_ANDROID_BIN"
elif command -v auto-android >/dev/null 2>&1; then
  BIN="$(command -v auto-android)"
elif [ -x "$PROJECT_ROOT/cli/.build/debug/auto-android" ]; then
  BIN="$PROJECT_ROOT/cli/.build/debug/auto-android"
else
  echo "ERROR: auto-android no encontrado."
  echo "Compila con: ./cli/dev-install.sh  (o: cd cli && swift build)"
  exit 1
fi

# ── Directorios de trabajo ──────────────────────────────────────────────
if [ -z "$RESULTS_DIR" ]; then
  RESULTS_DIR="$(mktemp -d /tmp/autopilot-benchmark.XXXXXX)"
fi
mkdir -p "$RESULTS_DIR" "$RESULTS_DIR/flows"

now_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# ── Lanes ───────────────────────────────────────────────────────────────
LANES="agent"
[ "$SKIP_LEGACY" = 1 ] || LANES="$LANES legacy"
MAESTRO_AVAILABLE=0
if [ "$SKIP_MAESTRO" = 1 ]; then
  echo "[maestro] Omitido (--skip-maestro)"
elif [ -x "$MAESTRO_BIN" ]; then
  MAESTRO_AVAILABLE=1
  LANES="$LANES maestro"
else
  echo "[maestro] No instalado en $MAESTRO_BIN — se omite ese lane."
  echo "          Instalar con: curl -Ls https://get.maestro.mobile.dev | bash"
fi

OPS="ping tree tap screenshot swipe"

lane_label() {
  case "$1" in
    agent)   echo "AgentBridge" ;;
    legacy)  echo "AdbLegacyBridge" ;;
    maestro) echo "Maestro" ;;
  esac
}

# ── Flows Maestro (generados) ───────────────────────────────────────────
write_maestro_flows() {
  cat > "$RESULTS_DIR/flows/tap.yaml" <<EOF
appId: $PKG
---
- tapOn: "Explorea"
EOF
  cat > "$RESULTS_DIR/flows/screenshot.yaml" <<EOF
appId: $PKG
---
- takeScreenshot: $RESULTS_DIR/maestro-shot
EOF
  cat > "$RESULTS_DIR/flows/swipe.yaml" <<EOF
appId: $PKG
---
- swipe:
    direction: UP
    duration: 400
EOF
}

# ── Device helpers ──────────────────────────────────────────────────────
SCREEN_W=1080
SCREEN_H=2400

detect_screen() {
  local size
  size="$(adb shell wm size 2>/dev/null | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -1)"
  if [ -n "$size" ]; then
    SCREEN_W="${size% *}"
    SCREEN_H="${size#* }"
  fi
}

relaunch_app() {
  [ "$DRY_RUN" = 1 ] && return 0
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb shell am start -n "$ACTIVITY" >/dev/null 2>&1 \
    || adb shell monkey -p "$PKG" 1 >/dev/null 2>&1 || true
  sleep 3
}

# Deshace el swipe up medido (via adb puro para no interferir con el lane).
restore_swipe() {
  [ "$DRY_RUN" = 1 ] && return 0
  adb shell input swipe "$((SCREEN_W / 2))" "$((SCREEN_H * 3 / 10))" \
    "$((SCREEN_W / 2))" "$((SCREEN_H * 7 / 10))" 300 >/dev/null 2>&1 || true
  sleep 1
}

agent_running() {
  "$BIN" agent status 2>/dev/null | grep -q "Agent running"
}

AGENT_STOPPED=0
restore_agent() {
  if [ "$AGENT_STOPPED" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    echo ""
    echo "[cleanup] Relanzando agente..."
    if ! "$BIN" agent start >/dev/null 2>&1; then
      echo "[cleanup] agent start fallo — si Maestro dejo colgada la"
      echo "          instrumentacion, correr: ./scripts/maestro-reset.sh"
    fi
  fi
}
trap restore_agent EXIT

# ── Ejecucion de una operacion ──────────────────────────────────────────
# exec_op lane op → corre UNA invocacion, deja exit code en $?
exec_op() {
  local lane="$1" op="$2"
  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi
  case "$lane" in
    agent)
      case "$op" in
        ping)        "$BIN" ping ;;
        tree)        "$BIN" tree ;;
        tap)         "$BIN" tap "Explorea" ;;
        screenshot)  "$BIN" screenshot "$RESULTS_DIR/shot.png" ;;
        swipe)       "$BIN" swipe up ;;
      esac
      ;;
    legacy)
      case "$op" in
        ping)        "$BIN" --legacy ping ;;
        tree)        "$BIN" --legacy tree ;;
        tap)         "$BIN" --legacy tap "Explorea" ;;
        screenshot)  "$BIN" --legacy screenshot "$RESULTS_DIR/shot.png" ;;
        swipe)       "$BIN" --legacy swipe up ;;
      esac
      ;;
    maestro)
      case "$op" in
        ping)        return 0 ;;  # sin equivalente — no se mide
        tree)        MAESTRO_CLI_NO_ANALYTICS=1 "$MAESTRO_BIN" hierarchy ;;
        *)           MAESTRO_CLI_NO_ANALYTICS=1 "$MAESTRO_BIN" test "$RESULTS_DIR/flows/$op.yaml" ;;
      esac
      ;;
  esac
}

# run_op lane op → warmup + N mediciones, escribe times/fails/jsonl
run_op() {
  local lane="$1" op="$2"
  local times_file="$RESULTS_DIR/times-$lane-$op.txt"
  local jsonl_file="$RESULTS_DIR/$lane-$op.jsonl"
  local fails=0 i start end ms code

  # Maestro no tiene equivalente de ping
  if [ "$lane" = "maestro" ] && [ "$op" = "ping" ]; then
    return 0
  fi

  : > "$times_file"
  : > "$jsonl_file"

  echo ">>> [$(lane_label "$lane")] $op: $WARMUP_RUNS warmup + $ITERATIONS runs"

  for i in $(seq 0 "$ITERATIONS"); do
    start=$(now_ms)
    set +e
    exec_op "$lane" "$op" > "$RESULTS_DIR/last-run.log" 2>&1
    code=$?
    set -e
    end=$(now_ms)
    ms=$((end - start))

    if [ "$i" = 0 ]; then
      # warmup — descartado
      [ "$op" = "swipe" ] && restore_swipe
      continue
    fi

    echo "{\"tool\":\"$lane\",\"test\":\"$op\",\"run\":$i,\"total_ms\":$ms,\"exit_code\":$code}" >> "$jsonl_file"
    if [ "$code" = 0 ]; then
      echo "$ms" >> "$times_file"
      echo "    run $i: ${ms}ms"
    else
      fails=$((fails + 1))
      echo "    run $i: FAIL (exit $code, ${ms}ms) — ver $RESULTS_DIR/last-run.log"
    fi

    [ "$op" = "swipe" ] && restore_swipe
  done

  echo "$fails" > "$RESULTS_DIR/fails-$lane-$op.txt"
}

# ── Estadistica (nearest-rank) ──────────────────────────────────────────
percentile() {
  local file="$1" pct="$2"
  if [ ! -s "$file" ]; then
    echo "-"
    return 0
  fi
  sort -n "$file" | awk -v p="$pct" '
    { v[NR] = $1 }
    END {
      r = int((p * NR + 99) / 100)
      if (r < 1) r = 1
      if (r > NR) r = NR
      print v[r]
    }'
}

# cell lane op → "p50 / p95" (+ tasa de exito si hubo fallos)
cell() {
  local lane="$1" op="$2"
  local times_file="$RESULTS_DIR/times-$lane-$op.txt"
  local fails_file="$RESULTS_DIR/fails-$lane-$op.txt"

  if [ "$lane" = "maestro" ] && [ "$op" = "ping" ]; then
    echo "n/a"
    return 0
  fi
  if [ ! -s "$times_file" ]; then
    echo "fallo (0/$ITERATIONS)"
    return 0
  fi

  local p50 p95 fails ok
  p50=$(percentile "$times_file" 50)
  p95=$(percentile "$times_file" 95)
  fails=$(cat "$fails_file" 2>/dev/null || echo 0)
  ok=$((ITERATIONS - fails))
  if [ "$fails" -gt 0 ]; then
    echo "$p50 / $p95 ($ok/$ITERATIONS ok)"
  else
    echo "$p50 / $p95"
  fi
}

# ── Reporte markdown ────────────────────────────────────────────────────
write_report() {
  local out="$1"
  local fecha device_info sdk maestro_ver commit lane op

  fecha="$(date '+%Y-%m-%d %H:%M')"
  commit="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
  if [ "$DRY_RUN" = 1 ]; then
    device_info="(dry-run, sin device)"
    sdk="n/a"
  else
    device_info="$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo 'n/a')"
    sdk="$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || echo 'n/a')"
  fi
  if [ "$MAESTRO_AVAILABLE" = 1 ]; then
    maestro_ver="$("$MAESTRO_BIN" --version 2>/dev/null | tail -1 || echo 'n/a')"
  else
    maestro_ver="no instalado"
  fi

  {
    echo "# Benchmark de bridges Android — $fecha"
    echo ""
    if [ "$DRY_RUN" = 1 ]; then
      echo "> **DRY RUN** — pipeline validado sin device; los tiempos no son reales."
      echo ""
    fi
    echo "Comparativa de latencia por operacion contra la demo app Explorea"
    echo "(\`$PKG\`). Issue #62."
    echo ""
    echo "| Parametro | Valor |"
    echo "|-----------|-------|"
    echo "| Fecha | $fecha |"
    echo "| Commit | \`$commit\` |"
    echo "| Device | $device_info (API $sdk) |"
    echo "| Iteraciones | $ITERATIONS medidas + $WARMUP_RUNS warmup |"
    echo "| auto-android | \`$BIN\` |"
    echo "| Maestro | $maestro_ver |"
    echo ""
    echo "## Resultados (ms, p50 / p95)"
    echo ""

    # Header dinamico segun lanes activos
    local header="| Operacion |"
    local sep="|-----------|"
    for lane in $LANES; do
      header="$header $(lane_label "$lane") |"
      sep="$sep---:|"
    done
    echo "$header"
    echo "$sep"

    for op in $OPS; do
      local row="| $op |"
      for lane in $LANES; do
        row="$row $(cell "$lane" "$op") |"
      done
      echo "$row"
    done

    echo ""
    echo "## Metodologia"
    echo ""
    echo "- Cada invocacion es un proceso frio del CLI completo — misma"
    echo "  penalizacion de arranque para todas las herramientas. Es la"
    echo "  latencia real que ve un usuario por comando."
    echo "- \`tap\` es semantico (label \`Explorea\` en la pantalla de auth):"
    echo "  incluye fetch del arbol + resolucion + tap."
    echo "- \`swipe\` mide \`swipe up\`; entre corridas se restaura la posicion"
    echo "  con un swipe down via adb puro (no medido)."
    echo "- AdbLegacyBridge corre con el agente detenido (\`agent stop\`):"
    echo "  Android permite un solo cliente UiAutomation (#135)."
    echo "- Maestro tambien usa UiAutomator, asi que corre con el agente"
    echo "  detenido. Cada operacion es \`maestro test <flow>.yaml\` (o"
    echo "  \`maestro hierarchy\` para tree) e incluye el arranque de la JVM,"
    echo "  identico a como se invoca desde una terminal."
    echo "- \`ping\` no tiene equivalente en Maestro."
    echo "- Percentiles nearest-rank sobre las corridas exitosas; los fallos"
    echo "  se reportan como \`(ok/N)\`."
    echo ""
    echo "Datos crudos: \`$RESULTS_DIR\` (jsonl por lane y operacion)."
  } > "$out"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "=== Benchmark #62: AgentBridge vs AdbLegacyBridge vs Maestro ==="
echo ""
echo "auto-android: $BIN"
echo "Iteraciones:  $ITERATIONS (+$WARMUP_RUNS warmup)"
echo "Resultados:   $RESULTS_DIR"
[ "$DRY_RUN" = 1 ] && echo "Modo:         DRY RUN (sin device, tiempos ficticios)"
echo ""

if [ "$DRY_RUN" = 0 ]; then
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb no encontrado en PATH. Ver docs/android/SDK-SETUP.md"
    exit 1
  fi
  if [ "$(adb get-state 2>/dev/null || true)" != "device" ]; then
    echo "ERROR: no hay device/emulador conectado (adb devices)."
    exit 1
  fi
  if ! adb shell pm path "$PKG" >/dev/null 2>&1; then
    echo "ERROR: $PKG no esta instalada. Correr: auto-android setup"
    echo "       (o instalar Demo/Android/TestAutomatitacion)"
    exit 1
  fi
  detect_screen
fi

[ "$MAESTRO_AVAILABLE" = 1 ] && write_maestro_flows
[ "$DRY_RUN" = 1 ] && [ "$MAESTRO_AVAILABLE" = 0 ] && write_maestro_flows

for lane in $LANES; do
  echo ""
  echo "════ Lane: $(lane_label "$lane") ════"

  if [ "$DRY_RUN" = 0 ]; then
    case "$lane" in
      agent)
        if ! agent_running; then
          echo "[agent] Arrancando agente..."
          "$BIN" agent start >/dev/null
        fi
        ;;
      legacy|maestro)
        # UiAutomation debe quedar libre (#135). Aplica a legacy Y a Maestro.
        if agent_running; then
          echo "[agent] Deteniendo agente (libera UiAutomation)..."
          "$BIN" agent stop >/dev/null
        fi
        AGENT_STOPPED=1
        ;;
    esac
    relaunch_app
  fi

  for op in $OPS; do
    run_op "$lane" "$op"
  done
done

# ── Reporte ─────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
  REPORT="$RESULTS_DIR/RESULTS-$(date +%Y-%m-%d).md"
else
  mkdir -p "$DOCS_DIR"
  REPORT="$DOCS_DIR/RESULTS-$(date +%Y-%m-%d).md"
fi
write_report "$REPORT"

echo ""
echo "════════════════════════════════════════════"
cat "$REPORT"
echo ""
echo "Reporte guardado en: $REPORT"
