#!/usr/bin/env bash
# Screenshot capture helpers

EVIDENCE_DIR="${EVIDENCE_DIR:-evidence}"

# capture_screenshot tool test step
capture_screenshot() {
  local tool="$1" test_name="$2" step="$3"
  local path="$EVIDENCE_DIR/${tool}-${test_name}-step${step}.png"
  xcrun simctl io booted screenshot "$path" 2>/dev/null || true
}
