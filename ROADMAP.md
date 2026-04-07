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

## Completado — Backend Android

Mismo protocolo (`DeviceBridge`), diferente backend. Dos binarios: `auto` (iOS) y `auto-android` (Android). El mismo script `.auto` funciona en ambos.

### Bridge ADB

**Enfoque tecnico:** Agente nativo (APK de instrumentacion) con `UiAutomation` directa + `LocalServerSocket`. Fallback a `adb` para operaciones de dispositivo.

- [x] `auto-android list` — `adb devices -l`
- [x] `auto-android launch <paquete>` — `adb shell monkey -p <pkg> -c LAUNCHER 1`
- [x] `auto-android terminate <paquete>` — `adb shell am force-stop`
- [x] `auto-android install <apk>` — `adb install -r`

### Inspeccion UI

- [x] `auto-android tree` — agente nativo con UiAutomation directa (3-6ms warm, 82x mas rapido que uiautomator dump)
- [x] `auto-android tree -s "query"` — busqueda recursiva en text/content-desc/resource-id

### Entrada

- [x] `auto-android tap "Login"` — dump UI → encontrar elemento → coordenadas → `adb shell input tap`
- [x] `auto-android type "texto"` — `adb shell input text` con escaping
- [x] `auto-android swipe up` — `adb shell input swipe` (40% de la pantalla)
- [x] `auto-android longPress`, `doubleTap`, `clear`, `scroll`, `tapAt`

### Arquitectura

- [x] Protocolo `DeviceBridge` con 22 metodos en `AutoCore`
- [x] `AgentBridge` (default) via socket al agente nativo + `AdbLegacyBridge` (`--legacy`) via `adb shell`
- [x] `UIAutomatorParser` convierte XML de uiautomator al formato compartido
- [x] `CommandDispatcher` compartido — misma logica para ambas plataformas
- [x] Dos binarios separados (no flag `--platform`)

### Pendiente Android

- [ ] Camera mock en Android
- [ ] Clipboard read via ADB (write funciona como workaround)
- [ ] Integrar biometrico en emulador (fingerprint enrollment)
- [ ] Soporte Android en el Editor Tauri

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

---

## Recomendaciones del experimento de validacion en apps reales

Sesion 2026-04-07. El experimento corrio el flow completo de login desde estado limpio en una app comercial real sobre iOS y Android. El CLI logro automatizarlo en ambas plataformas, pero aparecieron seis fricciones acotadas y tres mejoras de calidad de vida. Detalle completo en `docs/libro/14-validacion-en-una-app-real.md` y bitacora cruda en `docs/validacion/BITACORA.md`.

Todas las correcciones suman ~80 lineas de Swift sobre el bridge actual. No requieren cambios arquitectonicos ni dependencias nuevas.

### P0 — sin esto el flow real es fragil

- [ ] **`auto-android hideKeyboard` no cierra el teclado.** El comando retorna `Keyboard dismissed` pero el teclado sigue visible en pantalla, lo que rompe los `tap` posteriores sobre elementos tapados por el IME. Fix: en la rama Android del case `hideKeyboard` del `CommandDispatcher`, invocar internamente `pressKey back` que sí lo cierra. ~3 lineas en `cli/Sources/AutoCore/CommandDispatcher.swift`.

- [ ] **`ScriptParser` no expande variables de entorno.** Hoy las credenciales viven literales en el `.auto` y los secret scanners marcan el repo. Fix: agregar funcion `expand(_ token: String) -> String` que reemplace `$VAR` y `${VAR}` consultando `ProcessInfo.processInfo.environment[name]`, llamada desde `tokenize()` antes de retornar cada token. ~15 lineas en `cli/Sources/AutoCore/ScriptParser.swift`. Desbloquea pasar credenciales por env var sin tocar los scripts.

- [ ] **`auto clearState <bundleId>` no limpia el keychain en iOS.** El comando borra el data container de la app pero los items del keychain sobreviven, asi que el "estado limpio" prometido no es real cuando la app guarda tokens o credenciales ahi. Fix: en la rama iOS del dispatcher, agregar una llamada equivalente a `simctl spawn booted security delete-generic-password -s <bundleId>`. ~10 lineas en `CommandDispatcher.swift`. Garantiza el contrato del comando.

### P1 — reducen iteraciones

- [ ] **`auto-android scrollTo` parsea mal el segundo argumento.** El comando retorna `Invalid direction: . Use up/down/left/right` aunque la direccion se pase correctamente, porque el dispatcher Android lee mal el segundo token. Fix: corregir el indice del argumento en la rama Android del case `scrollTo`. ~2 lineas.

- [ ] **`auto dismissSystemDialog` para el dialog de Save Password de iOS.** El dialog del sistema de iOS aparece despues de un login exitoso y bloquea el siguiente paso del script. Fix: comando nuevo con heuristica que calcula las coordenadas del boton "Ahora no" en runtime usando el frame del simulator window expuesto via AX (es portable porque las coordenadas salen del AX, no son hardcodeadas). ~50 lineas en `SimulatorBridge.swift` + case en el dispatcher. Alternativa: si se implementa la limpieza de keychain (P0 #3), el dialog directamente no aparece porque iOS no tiene credenciales que ofrecer guardar — costo cero.

- [ ] **Wait implicito tras `pressKey back` y `hideKeyboard`.** Compose en Android necesita unos cientos de ms para re-renderizar el form despues de cerrar el IME, y sin la pausa el siguiente comando golpea el layout viejo. Fix: agregar un sleep breve al final de ambos casos en la rama Android del dispatcher. ~5 lineas.

### P2 — calidad de vida

- [ ] **`auto exists <bundleId>` para apps instaladas.** Hoy `exists` solo verifica elementos UI, no si una app esta instalada. Util para precondiciones de scripts y chequeos de setup en CI. Costo bajo, reusa `simctl get_app_container` (iOS) y `pm list packages` (Android).

- [ ] **Documentar el patron "tap por id" para Compose Android.** Los labels de Compose con caracteres especiales (apostrofes tipograficos U+2019, espacios no separables, etc.) rompen el match por texto y obligan a usar resource-id. Documentar el patron en `HALLAZGOS.md` o un quickstart de Android cambia significativamente la experiencia inicial.

- [ ] **`auto info <bundleId>` que muestre estado de la app.** Comando nuevo que reporta: si esta instalada, ruta del data container, items del keychain (iOS), permisos otorgados, version. Util para debug rapido sin abrir Xcode/Android Studio. Costo medio, todo via `simctl` y `pm dump`/`adb shell`.

### Costo total estimado

~80 lineas de codigo Swift, todas dentro del bridge actual. Ningun cambio arquitectonico, ninguna dependencia nueva. Las P0 son las que mas mueven la aguja: con esas tres correcciones el flow real corre limpio en ambas plataformas.
