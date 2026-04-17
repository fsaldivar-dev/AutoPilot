#!/bin/bash
# run-flakiness.sh <N>
#
# Repro for issue #80. Runs the flakiness-repro.auto script N times in a
# loop, uninstalling+installing the app between iterations. Captures per-
# iteration status + timing data (enabled via AUTO_DEBUG_TIMING=1).
#
# Prereqs:
#   - A simulator booted
#   - `Test Automatitacion.app` built under /tmp/explorea-build or passed
#     via EXPLOREA_APP env var
#   - `auto` in PATH
#
# Output: `flakiness-out.csv` with: iteration,status,elapsed_ms,first_fail_step

set -u
N="${1:-20}"
# SCRIPT defaults to the Settings regression script (no install/uninstall).
# For the full Explorea repro, pass scripts/benchmark-suite/flakiness-repro.auto
# and set EXPLOREA_APP to the built .app path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_FILE="${SCRIPT:-$SCRIPT_DIR/flakiness-settings.auto}"
BUNDLE_ID="${BUNDLE_ID:-com.apple.Preferences}"
APP_PATH="${EXPLOREA_APP:-}"
OUT_CSV="$SCRIPT_DIR/flakiness-out.csv"
LOG_FILE="$SCRIPT_DIR/flakiness-out.log"

echo "iteration,status,elapsed_ms,first_fail_step" > "$OUT_CSV"
: > "$LOG_FILE"

pass=0
fail=0
for i in $(seq 1 "$N"); do
  # Only uninstall/install when we have an APP_PATH (Explorea case).
  # For system apps (Settings), just terminate + relaunch by the script.
  if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    xcrun simctl uninstall booted "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install booted "$APP_PATH" >/dev/null 2>&1
  else
    xcrun simctl terminate booted "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  start=$(python3 -c 'import time; print(int(time.time()*1000))')
  out=$(AUTO_BRIDGE=simulator AUTO_DEBUG_TIMING=1 auto run "$SCRIPT_FILE" 2>&1 || true)
  end=$(python3 -c 'import time; print(int(time.time()*1000))')
  elapsed=$((end - start))

  # status: PASS if no "Timeout:" or "Error:" in output
  if echo "$out" | grep -qE "Timeout:|^Error:"; then
    status="FAIL"
    first_fail=$(echo "$out" | grep -oE "'[^']+' not found" | head -1 | tr -d "'" || echo "unknown")
    fail=$((fail + 1))
  else
    status="PASS"
    first_fail=""
    pass=$((pass + 1))
  fi

  echo "$i,$status,$elapsed,$first_fail" >> "$OUT_CSV"
  echo "=== iter $i [$status] ${elapsed}ms ===" >> "$LOG_FILE"
  echo "$out" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  printf "[%2d/%d] %s %dms %s\n" "$i" "$N" "$status" "$elapsed" "$first_fail"
done

echo ""
echo "Summary: ${pass}/${N} pass, ${fail}/${N} fail"
echo "Detailed log: $LOG_FILE"
echo "CSV: $OUT_CSV"
