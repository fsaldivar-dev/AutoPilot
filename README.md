<p align="center">
  <img src="assets/logo.png" alt="AutoPilot" width="500">
</p>

<p align="center">
  <strong>Controla el Simulador iOS directamente desde la terminal. Sin XCUITest. Sin servidor. Sin dependencias. Un solo binario.</strong>
</p>

<p align="center">
  <a href="#inicio-rapido">Inicio Rapido</a> •
  <a href="#comandos">Comandos</a> •
  <a href="#scripts">Scripts</a> •
  <a href="docs/ios/ARQUITECTURA.md">iOS</a> •
  <a href="docs/android/README.md">Android</a> •
  <a href="ROADMAP.md">Roadmap</a>
</p>

---

## Que es AutoPilot?

AutoPilot es una herramienta CLI que automatiza el Simulador iOS desde macOS. Un solo binario Swift, sin dependencias externas, sin servidor, sin compilacion por ejecucion.

```bash
auto launch com.example.app
auto tap "Iniciar Sesion"
auto type "Usuario" "correo@test.com"
auto screenshot resultado.png
```

### Por que existe?

| | AutoPilot | Appium/WDA | XCUITest | Detox |
|---|---|---|---|---|
| Tiempo de setup | `swift build` | Node + WDA + xcodebuild | Proyecto Xcode | npm + metro + build |
| Servidor | No | Si (WDA HTTP) | No | Si (gRPC) |
| Compilacion por ejecucion | No | WDA una vez | Cada ejecucion | Cada ejecucion |
| Dependencias | Ninguna | Node, Appium, WDA | Xcode | Node, React Native |
| Acceso a UI del sistema | Si (`tapAt`) | Limitado | Limitado | No |
| Tamano del binario | ~311KB | ~200MB+ | N/A | ~150MB+ |
| Camara virtual | **Si** (`--inject` / `auto build`) | No | No | No |

---

## Arquitectura General

AutoPilot esta disenado en capas. El CLI y el protocolo son agnosticos de plataforma. Cada plataforma tiene su propio backend.

```mermaid
graph TB
    subgraph CLI["CLI + Protocolo"]
        A[auto tap 'Login'] --> B[Dispatch de comandos]
        B --> C[Script Runner .auto]
    end

    subgraph iOS["Backend iOS"]
        D[AXUIElement<br/>Inspeccion UI]
        E[CGEvent<br/>Entrada de usuario]
        F[xcrun simctl<br/>Ciclo de vida]
        G[AppleScript<br/>Menus del Simulador]
    end

    subgraph Android["Backend Android - Futuro"]
        H[ADB<br/>Dispositivos]
        I[UIAutomator<br/>Inspeccion UI]
        J[adb shell input<br/>Entrada]
    end

    B --> D
    B --> E
    B --> F
    B --> G
    B -.-> H
    B -.-> I
    B -.-> J

    style CLI fill:#1E3A5F,color:#fff
    style iOS fill:#0a2540,color:#fff
    style Android fill:#333,color:#888
```

### Como funciona? (Vision general)

El Simulador iOS es una app de macOS (`Simulator.app`). macOS expone la interfaz de cualquier aplicacion a traves de las APIs de Accesibilidad. AutoPilot aprovecha esto para leer y controlar la UI del simulador **sin necesidad de un runner de pruebas dentro del simulador**.

```mermaid
sequenceDiagram
    participant T as Terminal
    participant A as auto (CLI)
    participant AX as macOS Accessibility
    participant S as Simulator.app
    participant iOS as App iOS

    T->>A: auto tap "Login"
    A->>AX: AXUIElementCreateApplication(pid)
    AX->>S: Leer arbol de accesibilidad
    S-->>AX: Elementos UI (botones, textos, campos)
    AX-->>A: AXUIElement del boton "Login"
    A->>AX: AXUIElementPerformAction(kAXPressAction)
    AX->>S: Ejecutar tap
    S->>iOS: Evento de toque
    iOS-->>S: UI actualizada
    A-->>T: Tapped 'Login' (89ms)
```

---

## Prerequisitos y Setup

### Que se necesita instalar/habilitar

```mermaid
flowchart LR
    subgraph Requisitos
        A[macOS 13+] --> B[Xcode + Simulador]
        B --> C[Swift 5.9+]
        C --> D["Permisos de Accesibilidad<br/>(TCC)"]
    end

    subgraph Habilitar["Habilitar acceso"]
        D --> E["System Settings<br/>Privacy & Security<br/>Accessibility"]
        E --> F["Agregar Terminal.app<br/>(o tu app de CI)"]
    end

    subgraph Resultado
        F --> G["auto puede leer<br/>el arbol AX del Simulador"]
        G --> H["auto puede enviar<br/>eventos CGEvent"]
    end

    style Habilitar fill:#1E3A5F,color:#fff
```

> **Importante:** Sin los permisos de Accesibilidad (TCC), `auto` no puede ver ni interactuar con el Simulador. En CI/CD esto se configura una vez en el runner.

### Compilar

```bash
cd cli
swift build -c release
cp .build/release/auto /usr/local/bin/auto
```

### Primera ejecucion

```bash
# Abrir el Simulador
open -a Simulator

# Verificar conexion
auto ping

# Ver el arbol de accesibilidad
auto tree

# Interactuar
auto tap "General"
```

---

## Stack Tecnologico

```mermaid
graph LR
    subgraph macOS["APIs de macOS"]
        AX["AXUIElement<br/><i>Accessibility Framework</i><br/>Leer UI"]
        CG["CGEvent<br/><i>Core Graphics</i><br/>Teclado + Mouse"]
        AS["osascript<br/><i>AppleScript</i><br/>Menus nativos"]
    end

    subgraph Apple["Herramientas Apple"]
        SC["xcrun simctl<br/>Gestion de simuladores"]
    end

    subgraph Auto["AutoPilot"]
        LIB["AutoLib<br/><i>SimulatorBridge.swift</i><br/><i>ScriptParser.swift</i><br/><i>TreePrinter.swift</i>"]
        CLI["CLI<br/><i>main.swift</i>"]
    end

    CLI --> LIB
    LIB --> AX
    LIB --> CG
    LIB --> AS
    LIB --> SC

    style Auto fill:#00D4FF,color:#000
    style macOS fill:#1E3A5F,color:#fff
    style Apple fill:#0a2540,color:#fff
```

### Que hace cada componente

| Componente | Que hace | Usado para |
|---|---|---|
| **AXUIElement** | Lee el arbol de UI del Simulador como elementos de accesibilidad | `tree`, `search`, `exists`, `tap`, `elementAt`, `waitFor` |
| **CGEvent** | Envia eventos de teclado y mouse al proceso del Simulador | `type`, `clear`, `swipe`, `scroll`, `longPress`, `tapAt` |
| **xcrun simctl** | Herramienta CLI de Apple para gestionar simuladores | `launch`, `terminate`, `screenshot`, `install`, `list`, `boot`, `media`, `paste`, `openurl` |
| **AppleScript** | Automatiza menus nativos de Simulator.app | `faceid` (enroll, match, fail) |

---

<h2 id="comandos">Comandos</h2>

### Gestion de Simuladores

```bash
auto ping                              # Verificar conexion
auto list                              # Listar simuladores (encendidos + disponibles)
auto boot "iPhone 16"                  # Encender por nombre
auto boot <UDID>                       # Encender por UDID
auto shutdown "iPhone 16"              # Apagar
```

### Ciclo de vida de apps

```bash
auto launch com.example.app            # Abrir app
auto terminate com.example.app         # Cerrar app
auto install /ruta/a/MiApp.app         # Instalar app
```

### Interaccion UI

```bash
auto tap "Iniciar Sesion"              # Tap por id/titulo/label/valor
auto doubleTap "Imagen"                # Doble tap
auto longPress "Elemento" 2            # Presion larga (2 seg, default: 1s)
auto type "Hola Mundo"                 # Escribir texto (campo enfocado)
auto type "Usuario" "correo@test.com"  # Tap en campo + escribir
auto clear "Usuario"                   # Seleccionar todo + borrar
auto swipe up                          # Deslizar pantalla completa
auto scroll "tableView" down           # Scroll dentro de un elemento
auto tapAt 200 400                     # Tap en coordenadas (UIs del sistema)
```

### Inspeccion UI

```bash
auto tree                              # Arbol de accesibilidad completo
auto tree -s "Login"                   # Buscar elementos por texto
auto exists "Bienvenido"               # SI/NO
auto elementAt 200 400                 # Elemento en coordenada
auto waitFor "Home" 10                 # Esperar hasta 10s a que aparezca
```

### Hardware y Datos

```bash
auto faceid enroll                     # Activar Face ID
auto faceid match                      # Simular escaneo exitoso
auto faceid fail                       # Simular escaneo fallido
auto faceid status                     # Verificar si esta activado
auto media foto.jpg                    # Inyectar foto a la galeria
auto paste "Hola"                      # Poner en portapapeles
auto paste                             # Leer portapapeles
auto openurl "miapp://ruta/profunda"   # Abrir URL / deep link
auto screenshot                        # Guardar como screenshot.png
auto screenshot resultado.png          # Nombre personalizado
```

### Camara Virtual

```bash
# Inyectar mock en cualquier app ya instalada (sin recompilar)
auto launch com.example.app --inject selfie.jpg
auto inject paisaje.jpg                          # Cambiar imagen en caliente

# O compilar con mock integrado (cuando tienes el proyecto)
auto build -project App.xcodeproj -scheme App \
    -sdk iphonesimulator -destination 'id=XXXX'
```

### Scripting

```bash
auto run flujo-login.auto              # Ejecutar script de automatizacion
```

---

<h2 id="scripts">Formato de Scripts (.auto)</h2>

Cada linea es un comando, igual que en la terminal. Comentarios con `#`. Strings entre comillas.

```bash
# flujo-login.auto
# Prueba el flujo completo de login

launch com.example.app
waitFor "Iniciar Sesion" 5

# Ingresar credenciales
tap "Usuario"
type "test@ejemplo.com"
tap "Contrasena"
type "secreto123"

# Enviar y verificar
tap "Entrar"
waitFor "Bienvenido" 10
screenshot login-exitoso.png
```

**Ejecucion:**

```
$ auto run flujo-login.auto
[1] launch com.example.app
Launched com.example.app (245ms)
[2] waitFor "Iniciar Sesion" 5
Found 'Iniciar Sesion' (1203ms)
[3] tap "Usuario"
Tapped 'Usuario' (89ms)
...
9 step(s) completed (5004ms)
```

**Comportamiento:**
- Pasos numerados secuencialmente
- Si falla: muestra numero de linea, error, y sale con codigo 1
- Lineas vacias y comentarios se ignoran

---

## Integracion CI/CD

Construido para CI/CD headless. Sin pantalla, sin webcam, sin interaccion humana.

```bash
# 1. Permisos de accesibilidad (una vez, necesita admin)
# Configurar en el runner de CI

# 2. Encender simulador
xcrun simctl boot "iPhone 16"
open -a Simulator
sleep 5

# 3. Ejecutar automatizacion
auto run pruebas-regresion.auto
echo "Codigo de salida: $?"  # 0 = exito, 1 = fallo
```

### Codigos de salida

| Codigo | Significado |
|---|---|
| 0 | Exito |
| 1 | Fallo (elemento no encontrado, timeout, error de simctl) |

---

## Camara Virtual (CI/CD sin webcam)

En CI/CD headless no hay webcam. El Simulador iOS no mapea camaras de macOS a `AVCaptureSession`. AutoPilot resuelve esto con dos enfoques:

### `launch --inject` — Inyeccion sin recompilar (recomendado)

Inyecta el mock de camara en **cualquier app ya instalada** via `DYLD_INSERT_LIBRARIES`. No necesitas el proyecto Xcode ni recompilar.

```bash
# 1. Lanzar app con mock de camara
auto launch com.example.app --inject selfie.jpg

# 2. La app usa la imagen inyectada al capturar foto
auto tap "Capturar"

# 3. Cambiar imagen en caliente (sin relanzar)
auto inject paisaje.jpg
auto tap "Capturar"
```

La dylib se compila una sola vez y se cachea en `~/.autopilot/`. Las ejecuciones siguientes son instantaneas.

### `auto build` — Inyeccion a nivel de compilacion

Cuando tienes el proyecto Xcode, `auto build` integra el mock directamente en el binario via `-force_load`.

```bash
auto build -project MiApp.xcodeproj -scheme MiApp \
    -sdk iphonesimulator -destination 'id=<UDID>'
auto install ~/Library/Developer/Xcode/DerivedData/.../MiApp.app
auto launch com.example.app
```

### Demo

https://github.com/fsaldivar-dev/AutoPilot/blob/main/assets/demos/demo-inject.mp4

### Como funciona

Ambos enfoques compilan el mismo codigo ObjC (~25 metodos swizzleados de AVFoundation) con `__attribute__((constructor))` que se ejecuta al cargar la app.

| | `launch --inject` | `auto build` |
|---|---|---|
| Necesita proyecto Xcode | No | Si |
| Modifica el binario | No (dylib externa) | Si (static lib linkada) |
| Cambio de imagen en caliente | Si (`auto inject`) | No (requiere relanzar) |
| Mecanismo | `DYLD_INSERT_LIBRARIES` | `-force_load` |

```mermaid
sequenceDiagram
    participant CLI as auto launch --inject
    participant DL as DYLD_INSERT_LIBRARIES
    participant App as App en Simulador

    CLI->>CLI: Compila dylib (una vez, cachea en ~/.autopilot/)
    CLI->>CLI: Copia imagen a /tmp/autopilot-camera-image.jpg
    CLI->>DL: simctl launch + DYLD_INSERT_LIBRARIES=dylib
    DL-->>App: App carga con dylib inyectada

    Note over App: Constructor swizzlea AVFoundation
    App->>App: capturePhoto → lee /tmp/autopilot-camera-image.jpg
    App->>App: delegate recibe AVCapturePhoto con datos

    Note over CLI,App: auto inject otra.jpg (hot-swap)
    CLI->>CLI: Copia nueva imagen a /tmp/autopilot-camera-image.jpg
    App->>App: Siguiente capturePhoto usa la nueva imagen
```

### APIs swizzleadas

| Clase | Metodos | Comportamiento mock |
|---|---|---|
| **AVCaptureDevice** | `authorizationStatus`, `requestAccess`, `defaultDevice` (x2) | Siempre autorizado, retorna mock device |
| **AVCaptureDeviceInput** | `initWithDevice:`, `deviceInputWithDevice:` | Acepta cualquier device |
| **AVCaptureSession** | `startRunning`, `stopRunning`, `isRunning`, `canAddInput/Output`, `addInput/Output`, `removeInput/Output`, `beginConfiguration`, `commitConfiguration`, `inputs`, `outputs` | No-ops, estado trackeado via associated objects |
| **AVCapturePhotoOutput** | `capturePhoto:delegate:` | Lee `AUTOPILOT_CAMERA_IMAGE`, crea `AVCapturePhoto`, llama delegate |
| **AVCapturePhoto** | `fileDataRepresentation`, `CGImageRepresentation`, `timestamp`, `photoCount`, `isRawPhoto` | Retorna datos de imagen inyectada |
| **AVCaptureMetadataOutput** | `setMetadataObjectsDelegate:`, `setMetadataObjectTypes:` | No-ops (QR scanner no crashea) |
| **AVCaptureVideoPreviewLayer** | `setSession:` | Preview con etiquetas "LIVE" + "AutoPilot \| Mock Camera" |

### Preview vs Captura

El preview layer simula un feed en vivo con etiquetas visuales. La foto capturada se entrega **limpia** (sin etiquetas):

| | Preview (AVCaptureVideoPreviewLayer) | Captura (fileDataRepresentation) |
|---|---|---|
| Imagen | Con overlay | Original, sin modificar |
| Etiqueta "LIVE" | Si (punto rojo + texto) | No |
| Banner "AutoPilot" | Si (pie semi-transparente) | No |
| Datos | Solo visual | `Data` completo para guardar/procesar |

### Variables de entorno

| Variable | Uso |
|---|---|
| `AUTOPILOT_CAMERA_IMAGE` | Ruta a imagen JPG/PNG en el Mac. Se inyecta como captura de camara. |
| `AUTOPILOT_QR_CODE` | String de codigo QR. Se inyecta directamente al delegate del scanner. |

### Ejemplo completo (CI/CD)

```bash
#!/bin/bash
# test-camara.sh — Prueba de captura de camara en CI

# Opcion A: sin recompilar (app ya instalada)
auto launch com.example.app --inject test-photo.jpg

# Opcion B: con recompilacion
# auto build -project App.xcodeproj -scheme App \
#     -sdk iphonesimulator -destination 'id=XXXX'
# auto install ~/Library/.../App.app
# auto launch com.example.app

auto waitFor "Capturar" 5
auto tap "Capturar"                    # Tap boton de captura
auto waitFor "Fotos capturadas" 5      # Verificar que se capturo
auto screenshot resultado-camara.png

# Probar con otra imagen
auto inject otra-foto.jpg
auto tap "Capturar"
auto screenshot resultado-camara-2.png
```

### Enfoques investigados

| # | Enfoque | Resultado |
|---|---|---|
| 1 | CMIOExtension | Codigo completo, bloqueado por entitlement Apple |
| 2 | Webcam del Mac | Simulador no mapea webcams a AVCaptureSession |
| 3 | Dylib ObjC injection | Swizzle OK, ARM64 PAC bloquea creacion de objetos |
| 4 | Variables de entorno | Funciona, requiere modificar codigo de la app |
| 5 | Swift dylib | Swizzle OK, closures ABI incompatible |
| 6 | Package + callback | Funciona, requiere 1 linea en la app |
| 7 | Pre-build script | Parcial, no alcanza dependencias SPM |
| 8 | VFS overlay + module map | Headers simplificados rompen modulo AVFoundation |
| 9 | **Force-load + #undef AV_INIT_UNAVAILABLE** | **Funciona. Sin modificar codigo de la app.** |
| 10 | **DYLD_INSERT_LIBRARIES + dylib** | **Funciona. Sin recompilar. Hot-swap de imagenes.** |

Validado con:
- **Demo app** (Explorea) — foto capturada, QR scanner, preview con labels
- **CameraTestApp** — app tercera AVFoundation puro, cero dependencias de AutoPilot

> **Documentacion completa:** [camera/BITACORA.md](camera/BITACORA.md) — 9 intentos documentados
> **Spec de env vars:** [docs/ios/VARIABLES_ENTORNO.md](docs/ios/VARIABLES_ENTORNO.md)

---

## AutoPilot Editor (IDE)

Editor visual para crear y ejecutar scripts `.auto`. Tauri + React + Monaco (~15MB).

```bash
cd editor && npm install && npm run tauri dev
```

### Features

| Feature | Descripcion |
|---|---|
| **Syntax Highlighting** | Keywords, strings, comentarios, numeros con tema oscuro |
| **Autocomplete** | 35+ comandos + elementos del Simulador en tiempo real |
| **Inspector Preview** | Screenshot real con overlays interactivos sobre cada elemento |
| **Inspector Tree** | Arbol jerarquico con `$N`, tipo, label, coordenadas |
| **Terminal** | Output en tiempo real, Play/Stop, Clear, abrir carpeta Screenshots |
| **Auto-wait** | AXObserver detecta cambios UI — sin sleeps manuales |
| **Duplicados** | `Camera[2]` selecciona el N-esimo duplicado (cross-platform) |
| **Config** | `auto config` guarda proyecto, scheme, bundle en `.autopilot` |

> **Documentacion completa del Editor:** [docs/editor/README.md](docs/editor/README.md)

---

## Documentacion Tecnica

| Plataforma | Estado | Documentacion |
|---|---|---|
| **iOS** | Funcional | [docs/ios/ARQUITECTURA.md](docs/ios/ARQUITECTURA.md) — AXUIElement, CGEvent, simctl, AppleScript, algoritmo de matching |
| **iOS Camara** | **Funcional** | [camera/BITACORA.md](camera/BITACORA.md) — 9 intentos, `auto build` con force-load swizzle |
| **iOS Env Vars** | Funcional | [docs/ios/VARIABLES_ENTORNO.md](docs/ios/VARIABLES_ENTORNO.md) — Inyeccion de datos para CI/CD |
| **Editor IDE** | **Funcional** | [docs/editor/README.md](docs/editor/README.md) — Tauri + React + Monaco |
| **Android** | Futuro | [docs/android/README.md](docs/android/README.md) — ADB, UIAutomator, adb shell input |

---

## Estructura del Proyecto

```
AutoPilot/
├── cli/                        # Paquete Swift (la herramienta)
│   ├── Package.swift           # Manifiesto SPM (macOS 13+, Swift 5.9)
│   ├── Sources/
│   │   ├── AutoLib/            # Libreria (testeable)
│   │   │   ├── SimulatorBridge.swift   # AX, CGEvent, simctl, AppleScript
│   │   │   ├── DylibInjector.swift    # auto inject: compila dylib, cachea en ~/.autopilot/
│   │   │   ├── BuildInterceptor.swift  # auto build: compila mock, wrapea xcodebuild
│   │   │   ├── MockHeaders.swift       # Codigo ObjC de swizzle (~25 metodos)
│   │   │   ├── ScriptParser.swift      # Tokenizador y parser de .auto
│   │   │   └── TreePrinter.swift       # Pretty-printer del arbol AX
│   │   └── CLI/
│   │       └── main.swift      # Punto de entrada, dispatch, script runner
│   └── Tests/                  # Tests unitarios (27 tests)
├── editor/                     # AutoPilot Editor (Tauri + React + Monaco)
│   ├── src/                    # Frontend React (App.tsx, Inspector.tsx)
│   └── src-tauri/              # Backend Rust (comandos auto)
├── camera/                     # Camara virtual
│   ├── CameraExtension/        # CMIOExtension (pendiente entitlement)
│   ├── CameraInject/           # Dylib ObjC (swizzle AVFoundation)
│   ├── AutoPilotCamera/        # App contenedora
│   ├── BITACORA.md             # Tropiezos y hallazgos
│   └── DESARROLLO.md           # Plan tecnico
├── protocol/
│   └── commands.json           # Especificacion de comandos (multi-plataforma)
├── scripts/examples/           # Scripts .auto de ejemplo
├── docs/
│   ├── ios/                    # Documentacion tecnica iOS
│   └── android/                # Documentacion tecnica Android
├── assets/                     # Logo e imagenes
├── Demo/                       # App iOS de ejemplo (SwiftUI)
├── legacy/                     # Arquitectura anterior (referencia)
├── .github/workflows/          # CI/CD (build, test, release)
├── README.md
└── ROADMAP.md
```

---

## Licencia

MIT
