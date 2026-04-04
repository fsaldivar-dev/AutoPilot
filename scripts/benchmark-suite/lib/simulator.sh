#!/usr/bin/env bash
# Simulator management

BUNDLE_ID="dev.autopilot.test.Explorea"

ensure_simulator_booted() {
  local booted
  booted=$(xcrun simctl list devices booted -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('state') == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)

  if [ -n "$booted" ]; then
    echo "Simulator already booted: $booted"
    return
  fi

  echo "Booting simulator..."
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime:
        continue
    for d in devices:
        if d.get('isAvailable') and 'iPhone' in d.get('name', ''):
            print(d['udid'])
            sys.exit(0)
")
  xcrun simctl boot "$udid"
  open -a Simulator
  sleep 5
  echo "Booted: $udid"
}

ensure_app_installed() {
  local project_root="$1"
  if xcrun simctl get_app_container booted "$BUNDLE_ID" > /dev/null 2>&1; then
    echo "App already installed: $BUNDLE_ID"
    return
  fi
  echo "App not installed. Please install $BUNDLE_ID first."
  exit 1
}

reset_app() {
  xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
}
