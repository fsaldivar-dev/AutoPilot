#!/bin/bash
# AutoPilot Post-Build Script
# Restaura los archivos originales despues de compilar.
#
# Uso en Xcode: Build Phases > New Run Script Phase (despues de Compile Sources)
#   bash packages/AutoPilotAVFoundation/Scripts/postbuild.sh "$SRCROOT"

set -e

SRCROOT="${1:-.}"
BACKUP_DIR="$SRCROOT/.autopilot-backup"

if [ ! -d "$BACKUP_DIR" ]; then
    exit 0
fi

echo "[AutoPilot] Post-build: restaurando archivos originales"

# Restaurar cada backup
find "$BACKUP_DIR" -name "*.swift" | while read BACKUP; do
    REL_PATH="${BACKUP#$BACKUP_DIR/}"
    ORIGINAL="$SRCROOT/$REL_PATH"
    cp "$BACKUP" "$ORIGINAL"
    echo "  ✓ $REL_PATH"
done

# Limpiar backups
rm -rf "$BACKUP_DIR"

echo "[AutoPilot] Post-build completo — archivos restaurados"
