#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────
TOTAL_RUNS="${TOTAL_RUNS:-11}"       # 1 warm-up + 10 medidas
WARMUP_RUNS=1
MEASURED_RUNS=$((TOTAL_RUNS - WARMUP_RUNS))
RESULTS_DIR="${RESULTS_DIR:-benchmark-results}"
AUTOPILOT_BIN="${AUTOPILOT_BIN:-./auto}"
MAESTRO_BIN="${MAESTRO_BIN:-$HOME/.maestro/bin/maestro}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="dev.autopilot.test.Explorea"

mkdir -p "$RESULTS_DIR"

# ── Timing (macOS date no soporta %N) ──────────────
now_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# ── Run single ─────────────────────────────────────
# Args: tool test_name run_number command...
run_single() {
  local tool="$1" test_name="$2" run_number="$3"
  shift 3

  local start_ms end_ms total_ms exit_code
  start_ms=$(now_ms)

  set +e
  "$@" > /dev/null 2>&1
  exit_code=$?
  set -e

  end_ms=$(now_ms)
  total_ms=$((end_ms - start_ms))

  echo "{\"tool\":\"$tool\",\"test\":\"$test_name\",\"run\":$run_number,\"total_ms\":$total_ms,\"exit_code\":$exit_code}"
}

# ── Run benchmark suite ────────────────────────────
# Args: tool test_name command...
run_benchmark() {
  local tool="$1" test_name="$2"
  shift 2
  local cmd=("$@")
  local outfile="$RESULTS_DIR/${tool}-${test_name}.jsonl"

  # Warm-up (descartada)
  echo ">>> [$tool] $test_name: warm-up..."
  run_single "$tool" "$test_name" 0 "${cmd[@]}" > /dev/null || true

  # Reset entre warm-up y mediciones
  xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
  sleep 1

  # Mediciones
  echo ">>> [$tool] $test_name: $MEASURED_RUNS runs..."
  for i in $(seq 1 "$MEASURED_RUNS"); do
    local result
    result=$(run_single "$tool" "$test_name" "$i" "${cmd[@]}")
    echo "$result" >> "$outfile"
    echo "    run $i: $(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['total_ms'])")ms"

    # Reset app entre runs
    xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
    sleep 1
  done
}

# ── Verificar herramientas ─────────────────────────
echo "=== Benchmark: AutoPilot vs Maestro ==="
echo ""

if ! command -v "$AUTOPILOT_BIN" &>/dev/null && [ ! -x "$AUTOPILOT_BIN" ]; then
  echo "ERROR: AutoPilot no encontrado en $AUTOPILOT_BIN"
  exit 1
fi

if ! command -v "$MAESTRO_BIN" &>/dev/null && [ ! -x "$MAESTRO_BIN" ]; then
  echo "ERROR: Maestro no encontrado en $MAESTRO_BIN"
  exit 1
fi

echo "AutoPilot: $AUTOPILOT_BIN"
echo "Maestro:   $MAESTRO_BIN"
echo "Runs:      $MEASURED_RUNS (+ $WARMUP_RUNS warm-up)"
echo ""

# ── AutoPilot benchmarks ──────────────────────────
run_benchmark "autopilot" "biometric" "$AUTOPILOT_BIN" run "$SCRIPT_DIR/biometric.auto"
run_benchmark "autopilot" "login"     "$AUTOPILOT_BIN" run "$SCRIPT_DIR/login.auto"

# ── Maestro benchmarks ────────────────────────────
run_benchmark "maestro" "biometric" "$MAESTRO_BIN" test "$SCRIPT_DIR/biometric.yaml"
run_benchmark "maestro" "login"     "$MAESTRO_BIN" test "$SCRIPT_DIR/login.yaml"

# ── Merge ─────────────────────────────────────────
cat "$RESULTS_DIR"/*.jsonl > "$RESULTS_DIR/all-results.jsonl"
echo ""
echo "=== Benchmark completo ==="
echo "Resultados: $RESULTS_DIR/all-results.jsonl"
