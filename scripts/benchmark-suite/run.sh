#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
export RESULTS_DIR="$SUITE_DIR/benchmark-results"
export EVIDENCE_DIR="$SUITE_DIR/evidence"
TOOLS_DIR="$SUITE_DIR/tools"
export TOTAL_RUNS="${TOTAL_RUNS:-11}"

# Source libraries
source "$SUITE_DIR/lib/timing.sh"
source "$SUITE_DIR/lib/screenshots.sh"
source "$SUITE_DIR/lib/simulator.sh"
source "$SUITE_DIR/lib/tools-setup.sh"

echo "╔══════════════════════════════════════════╗"
echo "║  Benchmark: AutoPilot vs Maestro vs WDA      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# 1. Create directories
mkdir -p "$RESULTS_DIR" "$EVIDENCE_DIR" "$TOOLS_DIR"
rm -f "$RESULTS_DIR"/*.jsonl "$EVIDENCE_DIR"/*.png

# 2. Setup tools
setup_tools "$TOOLS_DIR" "$PROJECT_ROOT"

# 3. Simulator
ensure_simulator_booted
ensure_app_installed "$PROJECT_ROOT"

# 4. Verify WDA is running (checked by setup_tools)

# Symlink evidence dir so relative paths from auto/maestro scripts work
ln -sfn "$EVIDENCE_DIR" "$PROJECT_ROOT/evidence"

echo ""
echo "=== Running benchmarks ==="
echo ""

# 5. Login test: all 3 tools
run_benchmark "autopilot" "login" \
  "$TOOLS_DIR/auto" run "$SUITE_DIR/tests/login.auto"

MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true \
run_benchmark "maestro" "login" \
  "$TOOLS_DIR/maestro" test --platform ios "$SUITE_DIR/tests/login.yaml"

if [ "${WDA_AVAILABLE:-0}" = "1" ]; then
  run_benchmark "wda" "login" \
    node "$SUITE_DIR/tests/login.js"
fi

# 6. Biometric test: AutoPilot + WDA (Maestro cannot)
run_benchmark "autopilot" "biometric" \
  "$TOOLS_DIR/auto" run "$SUITE_DIR/tests/biometric.auto"

if [ "${WDA_AVAILABLE:-0}" = "1" ]; then
  run_benchmark "wda" "biometric" \
    node "$SUITE_DIR/tests/biometric.js"
fi

# 7. Merge JSONL
cat "$RESULTS_DIR"/*.jsonl > "$RESULTS_DIR/all-results.jsonl" 2>/dev/null || true

# 9. Generate HTML report
python3 "$SUITE_DIR/report/generate-html.py" \
  "$RESULTS_DIR/all-results.jsonl" \
  "$EVIDENCE_DIR" \
  "$RESULTS_DIR/benchmark-report.html"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Suite complete!                            ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Report: $RESULTS_DIR/benchmark-report.html"

# 10. Copy comparison dashboard
cp "$SUITE_DIR/report/comparison-dashboard.html" "$RESULTS_DIR/comparison-dashboard.html"

# 11. Open reports
open "$RESULTS_DIR/comparison-dashboard.html" 2>/dev/null || true
echo "Dashboard: $RESULTS_DIR/comparison-dashboard.html"
