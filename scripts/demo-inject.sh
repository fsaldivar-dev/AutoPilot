#!/bin/bash
# demo-inject.sh — Demo completo de camera mock inject
# Graba pantalla completa (terminal + simulador) via ffmpeg
#
# Uso:
#   1. Abre Simulator + Terminal lado a lado
#   2. ./scripts/demo-inject.sh
#   3. El video queda en scripts/demo-inject.mp4
#
# Prerequisitos:
#   - Simulator corriendo con CameraTestApp instalada
#   - ffmpeg instalado (brew install ffmpeg)
#   - Permisos de grabacion de pantalla para Terminal

set -e
cd "$(dirname "$0")/.."

BUNDLE="dev.autopilot.test.CameraTestApp"
VIDEO="scripts/demo-inject.mp4"
SCREENSHOTS="scripts/demo-screenshots"
IMG1="scripts/demo-images/foto-1.jpg"
IMG2="scripts/demo-images/foto-2.jpg"

mkdir -p "$SCREENSHOTS"

# Verificar prerequisitos
if ! command -v ffmpeg &>/dev/null; then
    echo "Necesitas ffmpeg: brew install ffmpeg"
    exit 1
fi
if ! ./auto ping &>/dev/null; then
    echo "Simulator no esta corriendo. Abrelo primero."
    exit 1
fi

# Colores
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    sleep 2
}

# Simula typing del comando (para que se vea en el video)
run() {
    local cmd_str="./auto $*"
    echo ""
    echo -ne "${GREEN}\$ ${NC}"
    # Efecto de escritura letra por letra
    for (( i=0; i<${#cmd_str}; i++ )); do
        echo -n "${cmd_str:$i:1}"
        sleep 0.03
    done
    echo ""
    ./auto "$@"
    sleep 2
}

pause() {
    sleep "${1:-2}"
}

# ============================================================
# Empezar grabacion de pantalla completa
# ============================================================
echo -e "${BOLD}Iniciando grabacion de pantalla...${NC}"
echo -e "${YELLOW}(Si macOS pide permisos de grabacion, acepta y re-corre)${NC}"
echo ""

# ffmpeg: captura pantalla 0 (indice 3 en avfoundation), 30fps, calidad alta
ffmpeg -y -f avfoundation -framerate 30 -capture_cursor 1 -i "3:none" \
    -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
    "$VIDEO" &>/dev/null &
FFMPEG_PID=$!

# Verificar que ffmpeg arranco
sleep 2
if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    echo -e "\033[0;31mError: ffmpeg no pudo iniciar."
    echo "Verifica permisos: System Settings > Privacy > Screen Recording > Terminal${NC}"
    exit 1
fi

# Funcion para limpiar al salir
cleanup() {
    kill "$FFMPEG_PID" 2>/dev/null
    wait "$FFMPEG_PID" 2>/dev/null || true
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Video guardado: $VIDEO${NC}"
    echo -e "${GREEN}  Screenshots:    $SCREENSHOTS/${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
trap cleanup EXIT

# ============================================================
# PARTE 1: Sin inyeccion
# ============================================================
banner "PARTE 1 — Launch normal (sin camera mock)"

run launch "$BUNDLE"
pause 3

run screenshot "$SCREENSHOTS/01-sin-mock.png"
pause 1

banner "Sin webcam en el simulador, la camara no funciona"
pause 3

run terminate "$BUNDLE"
pause 2

# ============================================================
# PARTE 2: Con --inject
# ============================================================
banner "PARTE 2 — launch --inject foto-1.jpg"

run launch "$BUNDLE" --inject "$IMG1"
pause 4

run screenshot "$SCREENSHOTS/02-con-mock-preview.png"
pause 1

banner "La app muestra el mock de camara con la imagen inyectada"
pause 3

run tap "Capturar Foto"
pause 3

run screenshot "$SCREENSHOTS/03-foto-capturada.png"
pause 2

# ============================================================
# PARTE 3: Hot-swap
# ============================================================
banner "PARTE 3 — inject foto-2.jpg (hot-swap sin relanzar)"

run inject "$IMG2"
pause 2

banner "Imagen cambiada en caliente. La app sigue corriendo."
pause 2

run tap "Capturar Foto"
pause 3

run screenshot "$SCREENSHOTS/04-hot-swap.png"
pause 2

# ============================================================
# Fin
# ============================================================
banner "Demo completo"
pause 2

run terminate "$BUNDLE"
pause 1

# cleanup() se ejecuta automaticamente via trap EXIT
