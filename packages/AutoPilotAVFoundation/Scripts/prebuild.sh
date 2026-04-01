#!/bin/bash
# AutoPilot Pre-Build Script
# Reemplaza tipos de AVFoundation por nuestros proxies en archivos fuente.
# Solo se activa si AUTOPILOT_MOCK_CAMERA=1 esta seteado.
#
# Uso en Xcode: Build Phases > New Run Script Phase (antes de Compile Sources)
#   AUTOPILOT_MOCK_CAMERA=1 bash packages/AutoPilotAVFoundation/Scripts/prebuild.sh "$SRCROOT"

set -e

SRCROOT="${1:-.}"
BACKUP_DIR="$SRCROOT/.autopilot-backup"

# Solo activar si el flag esta seteado
if [ "$AUTOPILOT_MOCK_CAMERA" != "1" ]; then
    echo "[AutoPilot] Mock desactivado — sin cambios"
    exit 0
fi

echo "[AutoPilot] Pre-build: reemplazando tipos AVFoundation → AutoPilot"

# Crear directorio de backup
mkdir -p "$BACKUP_DIR"

# Buscar archivos Swift que usen AVCapture (excluyendo el package mismo y Pods)
FILES=$(grep -rl "AVCapture\|AVCapturePhotoCaptureDelegate" "$SRCROOT" \
    --include="*.swift" \
    --exclude-dir=".build" \
    --exclude-dir="Pods" \
    --exclude-dir="packages" \
    --exclude-dir=".autopilot-backup" \
    --exclude-dir="DerivedData" \
    2>/dev/null || true)

if [ -z "$FILES" ]; then
    echo "[AutoPilot] No se encontraron archivos con AVCapture"
    exit 0
fi

for FILE in $FILES; do
    # Backup del original
    REL_PATH="${FILE#$SRCROOT/}"
    BACKUP_PATH="$BACKUP_DIR/$REL_PATH"
    mkdir -p "$(dirname "$BACKUP_PATH")"
    cp "$FILE" "$BACKUP_PATH"

    # Agregar import de nuestro package si no esta
    if ! grep -q "import AutoPilotAVFoundation" "$FILE"; then
        sed -i '' 's/import AVFoundation/import AVFoundation\nimport AutoPilotAVFoundation/' "$FILE"
    fi

    # Reemplazar tipos
    sed -i '' \
        -e 's/AVCapturePhotoCaptureDelegate/AutoPilotPhotoCaptureDelegate/g' \
        -e 's/AVCapturePhotoSettings/AutoPilotCapturePhotoSettings/g' \
        -e 's/AVCapturePhotoOutput/AutoPilotCapturePhotoOutput/g' \
        -e 's/AVCapturePhoto\b/AutoPilotCapturePhoto/g' \
        -e 's/AVCaptureDeviceInput/AutoPilotCaptureDeviceInput/g' \
        -e 's/AVCaptureDevice\b/AutoPilotCaptureDevice/g' \
        -e 's/AVCaptureSession\b/AutoPilotCaptureSession/g' \
        "$FILE"

    echo "  ✓ $REL_PATH"
done

echo "[AutoPilot] Pre-build completo — $(echo "$FILES" | wc -l | tr -d ' ') archivo(s) modificados"
