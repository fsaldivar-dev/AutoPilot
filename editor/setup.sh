#!/bin/bash
# AutoPilot Editor — Setup
# Instala todas las dependencias necesarias para correr el editor.
# Uso: cd editor && ./setup.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }

echo ""
echo "AutoPilot Editor — Setup"
echo "========================"
echo ""

MISSING=0

# ── Node.js ──────────────────────────────────────────
if command -v node &>/dev/null; then
    ok "Node.js $(node --version)"
else
    fail "Node.js no encontrado"
    echo "  Instalar: brew install node"
    MISSING=1
fi

# ── npm ──────────────────────────────────────────────
if command -v npm &>/dev/null; then
    ok "npm $(npm --version)"
else
    fail "npm no encontrado"
    echo "  Instalar: brew install node"
    MISSING=1
fi

# ── Rust ─────────────────────────────────────────────
if command -v rustc &>/dev/null; then
    ok "Rust $(rustc --version | cut -d' ' -f2)"
else
    warn "Rust no encontrado — instalando via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
    source "$HOME/.cargo/env"
    if command -v rustc &>/dev/null; then
        ok "Rust $(rustc --version | cut -d' ' -f2) instalado"
    else
        fail "No se pudo instalar Rust"
        echo "  Instalar manualmente: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        MISSING=1
    fi
fi

# ── Cargo (viene con Rust) ───────────────────────────
if command -v cargo &>/dev/null; then
    ok "Cargo $(cargo --version | cut -d' ' -f2)"
else
    fail "Cargo no encontrado (deberia venir con Rust)"
    MISSING=1
fi

# ── Swift (para el CLI) ─────────────────────────────
if command -v swift &>/dev/null; then
    ok "Swift $(swift --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')"
else
    warn "Swift no encontrado — necesario para compilar el CLI"
    echo "  Instalar Xcode o Command Line Tools: xcode-select --install"
fi

# ── ADB (para Android) ──────────────────────────────
if command -v adb &>/dev/null || [ -f "$ANDROID_HOME/platform-tools/adb" ]; then
    ADB_PATH=$(command -v adb 2>/dev/null || echo "$ANDROID_HOME/platform-tools/adb")
    ok "ADB $($ADB_PATH version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
else
    warn "ADB no encontrado — necesario solo para auto-android"
    echo "  Instalar Android SDK o: brew install android-platform-tools"
fi

if [ $MISSING -eq 1 ]; then
    echo ""
    fail "Faltan dependencias obligatorias. Instalalas y corre ./setup.sh de nuevo."
    exit 1
fi

echo ""
echo "Instalando dependencias..."
echo ""

# ── npm dependencies ─────────────────────────────────
echo "npm install..."
npm install --silent 2>&1 | tail -1
ok "Dependencias npm instaladas"

# ── Compilar CLI (ambos binarios) ────────────────────
echo ""
echo "Compilando CLI..."
cd ../cli
swift build 2>&1 | tail -1
ok "auto (iOS) compilado"
ok "auto-android compilado"

# Copy for tauri dev (relative path resolution)
cp .build/debug/auto ../auto 2>/dev/null || true
cp .build/debug/auto-android ../auto-android 2>/dev/null || true

# Copy for tauri build (externalBin with target triple)
TARGET=$(rustc -vV 2>/dev/null | grep "host:" | awk '{print $2}')
TARGET=${TARGET:-aarch64-apple-darwin}
mkdir -p ../editor/src-tauri/binaries
cp .build/debug/auto "../editor/src-tauri/binaries/auto-${TARGET}"
cp .build/debug/auto-android "../editor/src-tauri/binaries/auto-android-${TARGET}"
ok "Binarios copiados para editor (dev + build)"
cd ../editor

echo ""
echo "========================"
ok "Setup completo"
echo ""
echo "Para iniciar el editor:"
echo "  npm run tauri dev"
echo ""
echo "Para compilar release:"
echo "  npm run tauri build"
echo ""
