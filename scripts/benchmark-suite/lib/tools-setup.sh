#!/usr/bin/env bash
# Download/copy tools into local sandbox

setup_tools() {
  local tools_dir="$1"
  local project_root="$2"

  echo "=== Setting up tools ==="

  # AutoPilot
  if [ -x "$tools_dir/auto" ]; then
    echo "[autopilot] Already exists"
  elif [ -x "$project_root/cli/.build/debug/auto" ]; then
    cp "$project_root/cli/.build/debug/auto" "$tools_dir/auto"
    echo "[autopilot] Copied from build"
  else
    echo "[autopilot] Building..."
    (cd "$project_root/cli" && swift build) > /dev/null 2>&1
    cp "$project_root/cli/.build/debug/auto" "$tools_dir/auto"
    echo "[autopilot] Built and copied"
  fi

  # Maestro
  if [ -x "$tools_dir/maestro" ]; then
    echo "[maestro] Already exists"
  elif [ -x "$HOME/.maestro/bin/maestro" ]; then
    ln -sf "$HOME/.maestro/bin/maestro" "$tools_dir/maestro"
    echo "[maestro] Linked from ~/.maestro/"
  else
    echo "[maestro] Downloading..."
    curl -Ls "https://get.maestro.mobile.dev" | bash > /dev/null 2>&1
    ln -sf "$HOME/.maestro/bin/maestro" "$tools_dir/maestro"
    echo "[maestro] Installed and linked"
  fi

  # WDA (WebDriverAgent) — must be running externally on port 8100
  local wda_port="${WDA_PORT:-8100}"
  if curl -s "http://127.0.0.1:$wda_port/status" | grep -q '"ready"' 2>/dev/null; then
    echo "[wda] Running on port $wda_port"
  else
    echo "[wda] ERROR: WebDriverAgent not running on port $wda_port"
    echo "      Start it with: xcodebuild test -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'platform=iOS Simulator,name=iPhone 16 Pro'"
    exit 1
  fi

  echo ""
}
