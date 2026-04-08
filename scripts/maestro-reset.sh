#!/usr/bin/env bash
# Maestro recovery script (#71)
#
# Cuando Maestro queda en estado inconsistente — driver crash, error 7001,
# session corrupta, conflicto con Appium uiautomator2 — este script ejecuta
# los pasos de recovery en el orden correcto.
#
# Usage:
#   ./scripts/maestro-reset.sh           # full reset
#   ./scripts/maestro-reset.sh --soft    # solo limpiar sessions, no desinstalar

set -euo pipefail

SOFT=0
for arg in "$@"; do
  case "$arg" in
    --soft) SOFT=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# *//'; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

echo "→ Maestro recovery"
echo ""

# 1. Limpiar sessions corruptas
SESSIONS_DIR="$HOME/.maestro/sessions"
if [ -d "$SESSIONS_DIR" ]; then
  count=$(find "$SESSIONS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    echo "→ Limpiando $SESSIONS_DIR ($count archivos)"
    rm -rf "$SESSIONS_DIR"/*
    echo "✓ Sessions limpiadas"
  else
    echo "✓ Sessions ya vacias"
  fi
else
  echo "~ ~/.maestro/sessions no existe (Maestro no instalado?)"
fi

if [ "$SOFT" -eq 1 ]; then
  echo ""
  echo "✓ Soft reset complete"
  echo ""
  echo "Reintenta tu test con:"
  echo "  export MAESTRO_DRIVER_STARTUP_TIMEOUT=180000"
  echo "  maestro test --device emulator-5554 tu-flow.yaml"
  exit 0
fi

# 2. Desinstalar paquetes Maestro del emulador
echo ""
echo "→ Desinstalando paquetes Maestro del emulador"
adb uninstall dev.mobile.maestro 2>/dev/null && echo "✓ dev.mobile.maestro" || echo "~ dev.mobile.maestro no estaba instalado"
adb uninstall dev.mobile.maestro.test 2>/dev/null && echo "✓ dev.mobile.maestro.test" || echo "~ dev.mobile.maestro.test no estaba instalado"

# 3. Desinstalar Appium uiautomator2 si esta presente (conflicto comun)
echo ""
echo "→ Limpiando posibles conflictos con Appium"
adb uninstall io.appium.uiautomator2.server 2>/dev/null && echo "✓ io.appium.uiautomator2.server" || echo "~ no instalado"
adb uninstall io.appium.uiautomator2.server.test 2>/dev/null && echo "✓ io.appium.uiautomator2.server.test" || echo "~ no instalado"

echo ""
echo "✓ Hard reset complete"
echo ""
echo "Reintenta tu test con:"
echo "  export MAESTRO_DRIVER_STARTUP_TIMEOUT=180000"
echo "  maestro test --device emulator-5554 --reinstall-driver tu-flow.yaml"
echo ""
echo "Maestro reinstalara el driver automaticamente en el primer run."
