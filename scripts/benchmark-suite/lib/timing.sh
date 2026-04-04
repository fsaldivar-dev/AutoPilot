#!/usr/bin/env bash
# Shared timing functions for benchmark suite

RESULTS_DIR="${RESULTS_DIR:-benchmark-results}"
TOTAL_RUNS="${TOTAL_RUNS:-11}"
WARMUP_RUNS=1
MEASURED_RUNS=$((TOTAL_RUNS - WARMUP_RUNS))
BUNDLE_ID="dev.autopilot.test.Explorea"

now_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# run_single tool test run_number command...
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

# run_benchmark tool test command...
run_benchmark() {
  local tool="$1" test_name="$2"
  shift 2
  local cmd=("$@")
  local outfile="$RESULTS_DIR/${tool}-${test_name}.jsonl"

  echo ">>> [$tool] $test_name: warm-up..."
  run_single "$tool" "$test_name" 0 "${cmd[@]}" > /dev/null || true

  xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
  sleep 1

  echo ">>> [$tool] $test_name: $MEASURED_RUNS runs..."
  for i in $(seq 1 "$MEASURED_RUNS"); do
    local result
    result=$(run_single "$tool" "$test_name" "$i" "${cmd[@]}")
    echo "$result" >> "$outfile"

    local ms
    ms=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['total_ms'])")
    echo "    run $i: ${ms}ms"

    xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
    sleep 1
  done
}
