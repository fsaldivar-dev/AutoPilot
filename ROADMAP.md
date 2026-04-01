# AutoPilot — Hoja de Ruta

## Arquitectura

AutoPilot es un sistema por capas. El CLI y el protocolo son agnosticos de plataforma. Cada plataforma tiene su propio backend. Las funcionalidades se construyen sobre ambos.

```
┌──────────────────────────────────────────────────┐
│          CLI + Protocolo                         │
│    (comandos, scripting, formatos de salida)      │
├────────────────────────┬─────────────────────────┤
│    Backend: iOS        │    Backend: Android      │
│    AXUIElement         │    ADB                   │
│    CGEvent             │    UIAutomator           │
│    xcrun simctl        │    adb shell input       │
│    AppleScript         │                          │
│    CoreMediaIO (cam)   │                          │
├────────────────────────┴─────────────────────────┤
│          Funcionalidades                         │
│    interaccion, inspeccion, simulacion hardware,  │
│    scripting, assertions, reportes               │
└──────────────────────────────────────────────────┘
```

---

## Completado — v0.1

### Backend iOS: Nucleo

| Funcionalidad | Como funciona |
|---|---|
| Bridge AXUIElement | `AXUIElementCreateApplication(pid)` sobre Simulator.app, recorrido recursivo del arbol |
| Busqueda de elementos | Tres pasadas: exacto toda profundidad > contiene toda profundidad, con `kAXValueAttribute` para SwiftUI |
| Teclado CGEvent | Virtual key codes + modificadores shift, `postToPid()`, 30ms entre teclas |
| Mouse CGEvent | Click, drag, presion larga via eventos de mouse `CGEvent` |
| Posting global de eventos | `.cghidEventTap` para UIs del sistema (photo picker, alertas, share sheets) |
| Menus AppleScript | Face ID via System Events > proceso Simulator > barra de menus |

### Gestion de Dispositivos

- [x] `list` — `simctl list devices -j`, parseado, agrupado por estado
- [x] `boot` — `simctl boot` con resolucion de nombre a UDID
- [x] `shutdown` — `simctl shutdown` con resolucion de nombre a UDID
- [x] `install` — `simctl install` para bundles .app

### Interaccion UI

- [x] `tap` — AXPressAction con fallback a click CGEvent
- [x] `doubleTap` — dos llamadas AXPressAction, 100ms de separacion
- [x] `longPress` — CGEvent mouseDown, mantener N segundos, mouseUp
- [x] `type` — teclado CGEvent, elemento objetivo opcional (tap primero)
- [x] `clear` — tap + Cmd+A + Delete
- [x] `swipe` — drag de mouse CGEvent en 20 pasos sobre centro de ventana
- [x] `scroll` — drag de mouse CGEvent en 20 pasos sobre centro del elemento (distancia = 40% altura, max 200px)
- [x] `tapAt` — CGEvent global en coordenadas absolutas

### Inspeccion UI

- [x] `tree` — arbol AX completo, formateado con role/title/label/id/value/frame
- [x] `tree -s` — busqueda recursiva en role/title/label/id/value (case-insensitive)
- [x] `exists` — verificacion booleana (SI/NO)
- [x] `elementAt` — busqueda por coordenada, gana el elemento de menor area
- [x] `waitFor` — polling cada 500ms, timeout configurable (default 10s)

### Hardware y Datos

- [x] `faceid` — enroll/match/fail/status via automatizacion de menus AppleScript
- [x] `media` — `simctl addmedia` para fotos/videos
- [x] `paste` — `simctl pbcopy/pbpaste` para portapapeles
- [x] `openurl` — `simctl openurl` para deep links
- [x] `screenshot` — `simctl io screenshot`

### Scripting

- [x] Formato de scripts `.auto` — basado en lineas, comentarios con `#`
- [x] Tokenizador con soporte de strings entre comillas (simples y dobles)
- [x] Numeracion de pasos y tiempo por paso
- [x] Fallo rapido con numero de linea y reporte de error
- [x] Resumen de tiempo total transcurrido

---

## Fase 2 — Robustecimiento iOS

### Camara Virtual

El Simulador iOS usa la webcam del Mac para acceso a camara. En CI/CD no hay webcam. AutoPilot creara una camara virtual que transmite imagenes estaticas como feed de camara en vivo.

**Enfoque tecnico:** Plugin CoreMediaIO DAL (Device Abstraction Layer).

- Un bundle `.plugin` colocado en `/Library/CoreMediaIO/Plug-Ins/DAL/`
- macOS lo carga automaticamente como dispositivo de camara
- El Simulador (y cualquier app usando AVCaptureSession) lo ve como una webcam real
- El plugin lee de una ruta de archivo conocida y lo sirve como frames continuos
- `auto camera feed foto.jpg` actualiza el archivo, el feed de camara cambia

**Comandos:**
- [ ] `auto camera install` — copiar plugin DAL al directorio del sistema
- [ ] `auto camera feed <imagen>` — establecer la imagen a transmitir como camara
- [ ] `auto camera stop` — dejar de transmitir

**Casos de uso:** Escaneo de QR, funciones AR, captura de documentos, verificacion de selfie — todo testeable en CI/CD.

### Permisos

Otorgar o revocar permisos de apps sin interaccion del usuario.

**Enfoque tecnico:** `xcrun simctl privacy`

- [ ] `auto permissions <bundleId> camera grant`
- [ ] `auto permissions <bundleId> location grant`
- [ ] `auto permissions <bundleId> photos grant`
- [ ] `auto permissions <bundleId> notifications grant`
- [ ] `auto permissions <bundleId> all reset`

Servicios soportados: `camera`, `photos`, `location`, `contacts`, `calendar`, `microphone`, `notifications`, `homekit`, `health`, `siri`, `speech-recognition`.

### Ubicacion

Simular coordenadas GPS y rutas.

**Enfoque tecnico:** `xcrun simctl location`

- [ ] `auto location <lat> <lon>` — establecer ubicacion fija
- [ ] `auto location route <archivo.gpx>` — reproducir una ruta GPX
- [ ] `auto location clear` — resetear a ninguna

### Notificaciones Push

Enviar notificaciones push al simulador.

**Enfoque tecnico:** `xcrun simctl push`

- [ ] `auto push <bundleId> <payload.json>` — enviar desde archivo JSON
- [ ] `auto push <bundleId> --title "Titulo" --body "Cuerpo"` — notificacion inline

### Gestos Avanzados

- [ ] Drag and drop entre dos elementos
- [ ] Pinch in/out (zoom) — requiere simulacion de dos dedos via CGEvent
- [ ] Gesto de rotacion

---

## Fase 3 — Salida y Reportes

### Salida JSON

- [ ] Flag `--json` en todos los comandos
- [ ] `auto tree --json` — arbol completo como JSON (para comparacion estructural, assertions en CI)
- [ ] `auto list --json` — lista de dispositivos como JSON
- [ ] Salida legible por maquinas para integracion con pipelines (`jq`, scripts, dashboards)

### Assertions

Assertions basadas en codigos de salida para CI/CD:

- [ ] `auto assert exists "Login"` — exit 0 si existe, exit 1 si no
- [ ] `auto assert text "Bienvenido" "Hola, Usuario"` — exit 0 si el texto coincide
- [ ] `auto assert count "Cell" 5` — exit 0 si hay exactamente 5 elementos

### Reportes de Scripts

- [ ] `auto run --screenshots <dir> script.auto` — screenshot despues de cada paso
- [ ] Reporte HTML con screenshot por paso, estado pass/fail, tiempos
- [ ] Salida JUnit XML para integracion CI (Jenkins, GitHub Actions)

---

## Fase 4 — Lenguaje de Scripting

Extender los scripts `.auto` mas alla de secuencias simples de comandos:

### Variables

```bash
set $usuario "test@ejemplo.com"
set $contrasena "secreto123"
type "Email" $usuario
type "Contrasena" $contrasena
```

### Condicionales

```bash
if exists "Banner de Cookies"
    tap "Aceptar"
endif

if not exists "Error"
    screenshot exito.png
endif
```

### Ciclos

```bash
repeat 3
    swipe down
endrepeat
```

### Includes

```bash
include compartido/login.auto
# continua con el script actual
```

---

## Fase 5 — Backend Android

Mismo CLI, mismos comandos, diferente backend. El usuario no deberia necesitar saber si el dispositivo es iOS o Android.

### Bridge ADB

**Enfoque tecnico:** `adb` para gestion de dispositivos, `adb shell input` para interaccion, `uiautomator dump` para inspeccion de UI.

- [ ] `auto --platform android list` — `adb devices`
- [ ] `auto --platform android launch <paquete>` — `adb shell am start`
- [ ] `auto --platform android terminate <paquete>` — `adb shell am force-stop`
- [ ] `auto --platform android install <apk>` — `adb install`

### Inspeccion UI

- [ ] `auto --platform android tree` — `uiautomator dump` parseado al mismo formato de arbol
- [ ] `auto --platform android search "Login"` — mismo algoritmo de busqueda sobre XML de UIAutomator

### Entrada

- [ ] `auto --platform android tap "Login"` — coordenadas de uiautomator + `adb shell input tap`
- [ ] `auto --platform android type "texto"` — `adb shell input text`
- [ ] `auto --platform android swipe up` — `adb shell input swipe`

### Auto-Deteccion de Plataforma

- [ ] Auto-detectar: si el Simulador iOS esta corriendo, usar iOS. Si hay dispositivo ADB conectado, usar Android.
- [ ] Explicito: `--platform ios` / `--platform android`
- [ ] El `protocol/commands.json` sirve como contrato compartido para ambos backends

---

## Fase 6 — Distribucion

### Sistema de Build

- [ ] Makefile con targets `build`, `install`, `clean`, `test`
- [ ] Binario universal: `swift build --arch arm64 --arch x86_64`
- [ ] `make install` copia a `/usr/local/bin/auto`

### Homebrew

- [ ] Repositorio homebrew tap (`homebrew-autopilot`)
- [ ] `brew tap user/autopilot && brew install autopilot`
- [ ] Bottles para instalacion rapida

### GitHub Releases

- [ ] Binarios universales pre-compilados por release
- [ ] Checksums SHA256
- [ ] Changelog por version
- [ ] Workflow GitHub Actions: build + test + release

---

## Fase 7 — Red y Entorno

### Condicionamiento de Red

- [ ] Simular red lenta, perdida de paquetes, desconexion
- [ ] Integracion con Network Link Conditioner de macOS o APIs de `simctl` si disponibles

### Keychain

- [ ] Leer/escribir items del keychain en el simulador
- [ ] Resetear keychain para estado limpio de tests

### Variables de Entorno

- [ ] Pasar variables de entorno a la app al lanzar
- [ ] `auto launch com.example.app --env API_URL=https://staging.api.com`

---

## Vision a Futuro

- **Web API** — Wrapper HTTP/WebSocket sobre AutoPilot para control remoto desde cualquier lenguaje
- **Extension VS Code** — panel inspector, vista de arbol, ejecucion paso a paso de scripts
- **Regresion Visual** — comparacion estructural del arbol entre ejecuciones (no basada en pixeles, basada en estructura)
- **Ejecucion Paralela** — multiples simuladores, mismo script, concurrente
- **Grabador** — `CGEventTap` para interceptar clicks/taps y generar scripts `.auto`
