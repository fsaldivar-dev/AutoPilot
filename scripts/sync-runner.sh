#!/usr/bin/env bash
#
# sync-runner.sh — Sincroniza el código del runner xctest
#
# Fuente de verdad: runner/AutoPilotRunner/*.swift
# Destino:          Demo/iOS/Test Automatitacion/Test AutomatitacionUITests/
#
# Xcode usa folder reference en el UITests target, por lo que necesita los
# archivos físicamente en Demo/. Este script mantiene sincronizadas las copias.
#
# Correr:
#   - Después de editar cualquier archivo en runner/AutoPilotRunner/
#   - Antes de build-for-testing del runner
#
# Uso:
#   ./scripts/sync-runner.sh          # copia + avisa qué cambió
#   ./scripts/sync-runner.sh --check  # solo chequea si están sincronizados

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/runner/AutoPilotRunner"
DEST="$REPO_ROOT/Demo/iOS/Test Automatitacion/Test AutomatitacionUITests"

if [ ! -d "$SRC" ]; then
  echo "✗ source dir no existe: $SRC"
  exit 1
fi

if [ ! -d "$DEST" ]; then
  echo "✗ demo UITests dir no existe: $DEST"
  exit 1
fi

MODE="sync"
case "${1:-}" in
  --check) MODE="check" ;;
  -h|--help)
    echo "Usage: $0 [--check]"
    exit 0
    ;;
esac

CHANGED=0
for f in "$SRC"/*.swift; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  target="$DEST/$name"

  if [ ! -f "$target" ]; then
    if [ "$MODE" = "check" ]; then
      echo "✗ missing in demo: $name"
      CHANGED=$((CHANGED + 1))
    else
      cp "$f" "$target"
      echo "+ copied (new): $name"
      CHANGED=$((CHANGED + 1))
    fi
  elif ! diff -q "$f" "$target" > /dev/null 2>&1; then
    if [ "$MODE" = "check" ]; then
      echo "✗ differs: $name"
      CHANGED=$((CHANGED + 1))
    else
      cp "$f" "$target"
      echo "✓ updated: $name"
      CHANGED=$((CHANGED + 1))
    fi
  fi
done

if [ $CHANGED -eq 0 ]; then
  echo "✓ runner files in sync"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  echo ""
  echo "Run without --check to sync them: ./scripts/sync-runner.sh"
  exit 1
fi

echo ""
echo "▶ Siguiente paso: rebuild el runner para que Xcode vea los cambios"
echo "  cd 'Demo/iOS/Test Automatitacion'"
echo "  xcodebuild build-for-testing -project 'Test Automatitacion.xcodeproj' \\"
echo "    -scheme 'Test Automatitacion' -destination 'platform=iOS Simulator,id=<UDID>'"
