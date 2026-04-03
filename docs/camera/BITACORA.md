# Camara Virtual — Bitacora de Desarrollo

## Sesion 2026-04-01

### Objetivo
Inyectar imagenes como feed de camara al Simulador iOS sin modificar apps de terceros. Para CI/CD headless donde no hay webcam.

### Intento 1: CMIOExtension (camara virtual macOS)
**Resultado:** Codigo completo, compilacion exitosa, bloqueado por permisos.

- Creamos CameraProvider, CameraDevice, CameraStream en Swift puro
- La extension se embebe en AutoPilotCamera.app
- `OSSystemExtensionRequest` requiere que la app este en `/Applications/`
- Error: "Extension not found in App bundle" — la extension si esta, pero sin el entitlement aprobado por Apple no se activa
- `systemextensionsctl developer on` requiere SIP deshabilitado
- DAL plugin (legacy) removido en macOS 15

**Accion pendiente:** Solicitar entitlement en https://developer.apple.com/contact/request/system-extension/

### Intento 2: Webcam del Mac
**Resultado:** No funciona.

- `system_profiler SPCameraDataType` muestra FaceTime HD + iPhone via Continuity
- El Simulador tiene `com.apple.display.captureservice` activo
- Pero `AVCaptureDevice.default(.builtInWideAngleCamera, ...)` retorna `nil` en el Simulador
- El Simulador **no mapea** webcams de macOS a `AVCaptureSession` de apps iOS
- `simctl privacy grant camera` no cambia nada — no hay hardware de camara

### Intento 3: Dylib injection (DYLD_INSERT_LIBRARIES)
**Resultado:** Swizzle exitoso, inyeccion de datos bloqueada por PAC.

**Lo que funciono:**
- Dylib ObjC compilada para ios26.0-simulator, cargada via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`
- Swizzle de `authorizationStatus(.video)` → `.authorized` sin prompt
- Swizzle de `AVCaptureSession.startRunning()` → interceptado, evita crash de FigCaptureSession
- Swizzle de `capturePhotoWithSettings:delegate:` → interceptado exitosamente
- Runtime introspection (`class_copyMethodList`) encuentra selector `didFinishProcessingPhoto` en el delegate
- `class_copyIvarList` encuentra ivar `onPhotoCaptured` del CameraManager
- `isSourceTypeAvailable(.camera)` → `YES`
- `canAddInput/canAddOutput` → `YES`

**Lo que NO funciono:**
- `AVCapturePhoto` init marcado `NS_UNAVAILABLE` — no se puede instanciar
- Bypass via `objc_msgSend(alloc, init)` → crash por ARM64 PAC (Pointer Authentication Code)
- Subclase via `objc_allocateClassPair` + `class_addMethod` para `fileDataRepresentation` → PAC valida el objeto interno
- `object_getIvar` para acceder closure `onPhotoCaptured` → Swift closures no son ObjC blocks, distinta calling convention → `EXC_BAD_ACCESS`
- Casting closure a `void (^)(UIImage *)` → PC alignment failure

**Aprendizaje clave:** ObjC runtime puede interceptar pero no puede crear objetos Swift validos ni invocar closures Swift. Se necesita una dylib en Swift para la proxima iteracion.

### Intento 4: Variables de entorno (SOLUCION ACTUAL)
**Resultado:** Funciona. 11 lineas de codigo en la app.

**Flujo:**
```
auto launch app --env AUTOPILOT_CAMERA_IMAGE=/path/to/image.jpg
→ SIMCTL_CHILD_AUTOPILOT_CAMERA_IMAGE=/path xcrun simctl launch booted app
→ App arranca con env var
→ capturePhoto() detecta env var → carga imagen → onPhotoCaptured()
```

**Hallazgos durante la prueba:**
1. `/tmp/` del Simulador NO es `/tmp/` del Mac — el Simulador tiene su propio filesystem
2. `simctl spawn booted ls /path` confirma que el Simulador no ve rutas del Mac
3. Sin embargo, el proceso de la app SI corre como proceso macOS y SI puede leer rutas del Mac
4. `tap "Camera"` tapeaba el AXImage (icono) en vez del AXButton (boton) — resuelto con `tapAt` en coordenadas
5. `print()` de Swift no aparece en `log show` del Simulador — usar `NSLog` y buscar con `processImagePath CONTAINS`
6. La env var se confirmo con NSLog en `onAppear`

**Limitacion:** Solo funciona si controlas el codigo de la app. Para librerias de terceros, no aplica.

### Proxima iteracion: Swift dylib

**Hipotesis:** Si la dylib esta escrita en Swift (no ObjC), puede:
1. Crear objetos Swift validos (no tiene PAC issues al ser el mismo runtime)
2. Invocar closures Swift directamente
3. Swizzlear a nivel de protocolo (Protocol Witness Tables)

**Plan:**
1. Crear dylib en Swift que importe AVFoundation
2. Swizzlear `AVCapturePhotoOutput.capturePhoto(with:delegate:)`
3. Crear `AVCapturePhoto` subclass en Swift (bypass de init via reflection)
4. Llamar `delegate.photoOutput(_:didFinishProcessingPhoto:error:)` nativamente
5. Si funciona → cualquier app que use AVFoundation recibe la imagen inyectada sin modificar codigo

**Alternativa:** SPM Build Tool Plugin que genera wrappers automaticos en tiempo de compilacion.

## Sesion 2026-04-01 (continuacion)

### Intento 5: Swift dylib linkada como package
**Resultado:** Swizzle funciona, ivar access a closures crashea.

- Swift dylib con ObjC bridge (`__attribute__((constructor))`) se carga automaticamente
- Swizzle de authorizationStatus, requestAccess, startRunning, capturePhoto funciona
- capturePhoto intercepta correctamente y carga la imagen
- **Crash al acceder ivar `onPhotoCaptured`**: Swift closures en memoria no son function pointers simples, tienen contexto capturado + metadata que no se puede reinterpretar como `(UIImage) -> Void` via `ivar_getOffset` + `assumingMemoryBound`
- El crash ocurre tanto desde dylib inyectada como desde package linkado — no es PAC, es la ABI de Swift closures

### Intento 6: Package con callback registrado
**Resultado:** Funciona. App necesita 1 linea para registrar callback.

- Mismo swizzle que intento 5
- En vez de buscar callback via ivar, la app registra `AutoPilotCamera.onPhotoCaptured = callback`
- El swizzle de capturePhoto invoca el callback registrado
- **Probado end-to-end: 16 pasos, imagen inyectada, "Fotos capturadas 1"**
- Limitacion: requiere 1 linea en la app + el guard del boton

### Intento 7: Pre-build script reemplazo de tipos
**Resultado:** Parcial. Funciona para archivos del proyecto, no para dependencias SPM.

- Script prebuild reemplaza `AVCaptureDevice` → `AutoPilotCaptureDevice`, etc.
- Postbuild restaura originales
- **Problemas encontrados:**
  - Xcode sandbox (`ENABLE_USER_SCRIPT_SANDBOXING=YES`) bloqueaba escritura → solucionado con NO
  - Espacios en rutas de "Test Automatitacion" → solucionado con `IFS` y comillas
  - Conflictos de tipos: `AVCaptureDevice.default(for:)` retorna tipo real, `AutoPilotCaptureDeviceInput` espera nuestro tipo → solucionado con `init(device: Any)`
  - **No alcanza dependencias SPM** — solo modifica archivos del workspace

### Intento 8: Module map override (descartado)
**Objetivo:** VFS overlay + module map custom para reemplazar headers de AVFoundation.

**Resultado:** No funciona. Los headers simplificados rompen el modulo AVFoundation porque faltan tipos interdependientes (AVCaptureConnection, etc.). Intentamos:
- VFS overlay que redirige headers de captura → otros headers del framework referencian tipos faltantes
- Headers custom completos → demasiada superficie de API para mantener

### Intento 9: Force-load + swizzle con #undef AV_INIT_UNAVAILABLE
**Resultado:** FUNCIONA. Build completo sin errores.

**Enfoque:**
1. Compilamos un `.m` ObjC con `-fno-modules` que:
   - Importa `AVBase.h` primero, luego `#undef AV_INIT_UNAVAILABLE` y redefine como vacio
   - Importa `AVFoundation.h` — ahora `AVCapturePhoto` tiene init disponible
   - `__attribute__((constructor))` swizzlea todo al cargar:
     - `AVCaptureDevice.authorizationStatus` → `.authorized`
     - `AVCaptureDevice.requestAccess` → `YES`
     - `AVCaptureSession.startRunning/stopRunning` → no-op
     - `AVCaptureSession.canAddInput/canAddOutput` → `YES`
     - `AVCapturePhotoOutput.capturePhoto` → lee AUTOPILOT_CAMERA_IMAGE, crea AVCapturePhoto real via init, guarda datos con `objc_setAssociatedObject`
     - `AVCapturePhoto.fileDataRepresentation` → lee datos de associated object
     - `AVCapturePhoto.CGImageRepresentation` → idem
     - `AVCapturePhoto.timestamp/photoCount/isRawPhoto` → valores mock
2. Se compila a `libAutoPilotCapture.a` (static lib, ~20KB)
3. `auto build` wrapea xcodebuild con `OTHER_LDFLAGS=-force_load libAutoPilotCapture.a`

**Por que funciona:**
- `AV_INIT_UNAVAILABLE` es restriccion solo de compilador, no de runtime
- `#undef` + `#define` vacio elimina la restriccion en nuestro .m
- `[[AVCapturePhoto alloc] init]` funciona porque init es heredado de NSObject
- Associated objects evitan tocar ivars internos (_internal) → no PAC issues
- `-force_load` mete el constructor en el binario → swizzle ocurre al cargar
- No hay duplicacion de clases, solo swizzle de metodos existentes

**Probado end-to-end:**
1. `auto build` compila Demo app con mock inyectado (BUILD SUCCEEDED)
2. `simctl install` + `simctl launch --env AUTOPILOT_CAMERA_IMAGE=...`
3. Constructor swizzlea 20 metodos (auth, device, session, photo, input)
4. Tap boton captura → `capturePhoto intercepted` → `Loaded image (127KB)` → `Photo delivered to delegate`
5. UI muestra "Fotos capturadas: 1"

**Gotcha resuelto:** `class_addMethod` vs `method_setImplementation` — si el metodo esta heredado (no directamente en la clase), `method_setImplementation` modifica la superclase. `class_addMethod` lo agrega directamente a la clase.

**Gotcha resuelto:** Xcode 26 debug dylib — `ENABLE_DEBUG_DYLIB=NO` necesario para que `force_load` funcione en el binario principal.

**Metodos swizzleados (~25):**
- AVCaptureDevice: authorizationStatus, requestAccess, defaultDevice (2 variantes)
- AVCaptureDeviceInput: initWithDevice, deviceInputWithDevice
- AVCaptureSession: startRunning, stopRunning, isRunning, canAddInput, canAddOutput, addInput, addOutput, removeInput, removeOutput, beginConfiguration, commitConfiguration, inputs, outputs
- AVCapturePhotoOutput: capturePhoto
- AVCapturePhoto: fileDataRepresentation, CGImageRepresentation, timestamp, photoCount, isRawPhoto
- AVCaptureMetadataOutput: setMetadataObjectsDelegate, setMetadataObjectTypes
- AVCaptureVideoPreviewLayer: setSession (composita imagen con labels LIVE + AutoPilot)

**Preview layer:**
- Composita imagen a 400x600 con aspectFill propio
- Punto rojo + "LIVE" arriba izquierda (simula feed)
- Banner "AutoPilot | Mock Camera" abajo (identifica mock)
- `kCAGravityResize` para evitar doble crop
- La foto capturada se entrega SIN etiquetas (imagen limpia original)

**Validado con app de terceros (CameraTestApp):**
- App AVFoundation pura, sin AutoPilot, sin dependencias
- `auto build` + `simctl launch --env AUTOPILOT_CAMERA_IMAGE=...`
- Preview muestra imagen con labels LIVE + AutoPilot
- Captura: "Foto capturada (127925 bytes)", imagen limpia
- QR scanner: no crashea, preview funciona

**Archivos:**
- `cli/Sources/AutoLib/MockHeaders.swift` — codigo ObjC como string (~400 lineas)
- `cli/Sources/AutoLib/BuildInterceptor.swift` — orquestador: compila .m, wrapea xcodebuild
- `cli/Sources/CLI/main.swift` — case "build" agregado
- `cli/Sources/AutoLib/SimulatorBridge.swift` — metodo buildWithCameraMock
- `Demo/CameraTestApp/` — app tercera de prueba (AVFoundation puro)

### Resumen de archivos

| Archivo | Proposito | Estado |
|---|---|---|
| `cli/Sources/AutoLib/MockHeaders.swift` | Swizzle ObjC embebido (~25 metodos) | **Funcional** |
| `cli/Sources/AutoLib/BuildInterceptor.swift` | Compila .m, wrapea xcodebuild | **Funcional** |
| `Demo/CameraTestApp/` | App tercera para validar mock | **Probada** |
| `camera/CameraExtension/` | CMIOExtension Swift | Bloqueado por entitlement |
| `camera/CameraInject/AutoPilotCamera.m` | Dylib ObjC swizzle | Parcial (descartado) |
| `packages/AutoPilotAVFoundation/` | Package swizzle (requiere 1 linea en app) | Funcional, superado por auto build |

## Sesion 2026-04-02

### Editor IDE (AutoPilot Editor)

**Stack:** Tauri 2 + React + TypeScript + Monaco Editor

**Features implementados:**
- Monaco editor con syntax highlighting para lenguaje .auto
- Tema oscuro "AutoPilot" (Tokyo Night inspired)
- 35+ comandos en autocomplete con snippets
- Inspector visual: Preview (screenshot real + overlays) y Tree (jerarquico)
- Terminal inferior con Play/Stop/Clear/Screenshots
- Auto-wait via AXObserver (detecta cambios UI en tiempo real)
- Indexacion de elementos ($N) para desambiguar duplicados
- Sintaxis Camera[2] para seleccionar el N-esimo duplicado (cross-platform)
- Boton Screenshots para abrir carpeta en Finder

### CLI — Nuevos features

- `auto config` — configuracion persistente en .autopilot
- `auto build` sin args lee de .autopilot
- `auto launch` sin args lee bundle + image de .autopilot
- `auto index` — lista elementos con $N, tipo, label, coordenadas
- `auto index Camera` — filtra duplicados
- `auto inspect` — debug de atributos AX
- `tap Camera[2]` — tapea el N-esimo duplicado
- `tap 1,2,3,4,Confirmar` — multi-tap con comas
- Auto-wait entre comandos de scripts (AXObserver, sin polling)

### CI/CD — E2E Tests

- Workflow "E2E Tests" en GitHub Actions (macos-15)
- Hardware: Face ID enroll/match/status + pasteboard
- Camera: auto build + mock capture + screenshot
- Todo verde en 6 minutos

### Hallazgos

- SwiftUI NavigationBar buttons no se exponen via macOS AX (AXChildren=[0])
- AXObserver funciona para detectar cambios UI en tiempo real
- El arbol AX se resuelve en el mismo orden que UIAutomator → Camera[N] es cross-platform
- Xcode 26 ENABLE_DEBUG_DYLIB=NO necesario para force_load

### Intento 10: DYLD_INSERT_LIBRARIES + dylib (sin recompilar)
**Resultado:** FUNCIONA. Inyeccion en cualquier .app ya instalada sin proyecto Xcode.

**Motivacion:** El intento 9 (force-load) funciona perfecto pero requiere tener el proyecto Xcode y recompilar. Para apps de terceros o apps ya instaladas, eso no aplica. Necesitabamos un camino que no toque el binario.

**Enfoque:**
1. El mismo codigo ObjC de MockHeaders.swift se compila como **dylib** (shared library) en vez de static lib
2. Se cachea en `~/.autopilot/libAutoPilotCapture.dylib` — se compila una sola vez
3. `auto launch app --inject imagen.jpg` lanza la app con `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` apuntando a la dylib
4. El constructor se ejecuta igual que con force-load, swizzlea los mismos ~25 metodos

**Compilacion de la dylib:**
```bash
xcrun clang -dynamiclib -arch arm64 \
  -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) \
  -target arm64-apple-ios16.0-simulator \
  -fobjc-arc -fno-modules \
  -framework AVFoundation -framework UIKit \
  -framework CoreMedia -framework QuartzCore \
  AutoPilotCapture.m -o libAutoPilotCapture.dylib
```

**Tropiezo 1: Linker symbols faltantes**
- Primera compilacion fallo con `Undefined symbols: _CACurrentMediaTime, _kCAGravityResize`
- Causa: `ap_timestamp()` usa `CACurrentMediaTime()` y `ap_previewSetSession()` usa `kCAGravityResize`
- Ambos vienen de QuartzCore, que no estaba en los frameworks de la dylib
- Solucion: agregar `-framework QuartzCore` a los flags de clang

**Tropiezo 2: La env var AUTOPILOT_CAMERA_IMAGE es inmutable post-launch**
- El mock leia la imagen de `[NSProcessInfo processInfo].environment[@"AUTOPILOT_CAMERA_IMAGE"]`
- Esto se setea una vez al lanzar via `SIMCTL_CHILD_` y no cambia en runtime
- Para hot-swap de imagen sin relanzar, necesitabamos otro mecanismo
- Solucion: leer de un **path fijo** `/tmp/autopilot-camera-image.jpg` que se puede sobreescribir en cualquier momento

**Tropiezo 3: Constructor condicionado a env var**
- El constructor original solo activaba el swizzle si `AUTOPILOT_CAMERA_IMAGE` o `AUTOPILOT_QR_CODE` existian
- Con dylib injection, la dylib SOLO se carga cuando el usuario pide `--inject`, asi que siempre debe activarse
- Solucion: remover la condicion, siempre swizzlear cuando la dylib esta presente

**Hot-swap de imagen (`auto inject`):**
- Nuevo comando que copia una imagen a `/tmp/autopilot-camera-image.jpg`
- El mock lee de ese path **cada vez que se llama `capturePhoto`** (no cachea la imagen)
- Permite cambiar la imagen sin relanzar la app
- `ap_resolveImagePath()` busca en orden: path fijo → env var → nil (placeholder)

**Diseno del comando:**
- Primera iteracion: `auto inject com.example.app foto.jpg` — comando separado
- Segunda iteracion: `auto launch app --inject foto.jpg` — flag de launch (mas natural)
- El usuario sugierio que un comando separado no se sentia bien, que lanzar con inject era mas claro
- Ademas, `auto inject foto.jpg` (sin bundle) quedo como hot-swap mid-session

**Flujo final:**
```bash
# Lanzar con mock (compila dylib si no existe, cachea en ~/.autopilot/)
auto launch com.example.app --inject selfie.jpg

# Cambiar imagen sin relanzar
auto inject paisaje.jpg

# En script .auto
launch com.example.app --inject selfie.jpg
tap "Capturar"
inject paisaje.jpg
tap "Capturar"
```

**Probado end-to-end:**
1. `auto launch dev.autopilot.test.CameraTestApp --inject temp/test-image.jpg`
   - Dylib compilada (75KB), cacheada en ~/.autopilot/
   - App lanzada con DYLD_INSERT_LIBRARIES
   - Constructor swizzlea 25 metodos
   - Preview muestra imagen con labels LIVE + AutoPilot
2. `auto inject temp/test-image.jpg`
   - Imagen copiada a /tmp/autopilot-camera-image.jpg
   - Siguiente captura usa la nueva imagen
3. Grabado video demo (`scripts/demo-inject.sh`) con ffmpeg capturando pantalla completa

**Comparativa de enfoques:**

| | `launch --inject` (intento 10) | `auto build` (intento 9) |
|---|---|---|
| Necesita proyecto Xcode | No | Si |
| Modifica el binario | No (dylib externa) | Si (static lib linkada) |
| Hot-swap de imagen | Si (`auto inject`) | No (requiere relanzar) |
| Mecanismo | `DYLD_INSERT_LIBRARIES` | `-force_load` |
| Tamano | 75KB dylib | ~28KB static lib |
| Compilacion | Una vez (cacheada) | Cada build |

**Archivos nuevos/modificados:**

| Archivo | Cambio |
|---|---|
| `cli/Sources/AutoLib/DylibInjector.swift` | Nuevo — compila dylib, cachea en ~/.autopilot/ |
| `cli/Sources/AutoLib/MockHeaders.swift` | `ap_resolveImagePath()`, constructor sin condicion |
| `cli/Sources/AutoLib/SimulatorBridge.swift` | `injectAndLaunch()`, `setInjectImage()` |
| `cli/Sources/CLI/main.swift` | `launch --inject`, `inject` command |
| `scripts/demo-inject.sh` | Script de grabacion de demo |
| `assets/demos/` | Video + screenshots del demo |

**Hallazgos clave:**
- `DYLD_INSERT_LIBRARIES` funciona sin problemas en el Simulador iOS (no hay code signing enforcement como en dispositivo fisico)
- El Simulador comparte `/tmp/` con macOS — las apps del simulador pueden leer paths del Mac
- `-dynamiclib` requiere todos los frameworks como dependencias explicitas (a diferencia de static lib que los resuelve al linkear con el binario final)
- La dylib de 75KB es autocontenida — no necesita que la app tenga ningun framework extra
- El hot-swap funciona porque `capturePhoto` lee el archivo en cada invocacion, no lo cachea

## Sesion 2026-04-02 (tarde/noche) — Android + Editor multi-plataforma

### Lo que hicimos

**Limpieza:**
- Eliminamos `legacy/`, `protocol/`, `temp/`, y 4 subcarpetas de `camera/` (experimentos abandonados)
- Movimos docs de camera a `docs/camera/`
- Reorganizamos `Demo/` en `Demo/iOS/` y `Demo/Android/`

**Arquitectura multi-plataforma:**
- Extrajimos protocolo `DeviceBridge` (22 metodos) en `AutoCore`
- Movimos iOS a `AutoLibiOS` (SimulatorBridge, ElementIndex, TargetResolver, etc.)
- `AdbBridge` implementa `DeviceBridge` usando `adb shell` commands
- `UIAutomatorParser` parsea XML de `uiautomator dump` al formato compartido `[[String: Any]]`
- `CommandDispatcher` compartido — misma logica para ambas plataformas
- Dos binarios: `auto` (iOS) y `auto-android` (Android)

**Apps demo Android:**
- CameraTestApp: CameraX + Compose, espejo de la version iOS
- TestAutomatitacion (Explorea): app completa con auth, 4 tabs, 7 entries sample

**Editor con soporte Android:**
- Toggle iOS/Android en toolbar
- Backend Rust resuelve binario correcto segun plataforma

### Tropiezos y problemas sin resolver

**1. UIAutomatorParser — sufijo pegado al XML**
- `adb exec-out uiautomator dump /dev/tty` devuelve el XML con "UI hierchary dumped to: /dev/tty" pegado al final SIN newline
- El parser XML de Foundation fallaba (error 5) porque leia basura despues de `</hierarchy>`
- Solucion: truncar el string en `</hierarchy>` antes de parsear

**2. Editor — path del binario**
- El editor corre desde `editor/src-tauri/` (no la raiz del proyecto)
- Los binarios estan en `../../auto` y `../../auto-android`
- Teniamos un path hardcodeado a otra maquina: `/Users/franciscojaviersaldivarrubio/Documents/AutomationApp/auto`
- Tuvimos que buscar en 7 paths diferentes para cubrir dev, release, y PATH

**3. Editor — iconos PNG faltantes**
- `tauri.conf.json` referencia `32x32.png`, `128x128.png`, `128x128@2x.png` pero solo existian `.icns` y `.ico`
- La compilacion fallaba con "failed to open icon"
- Solucion: generar PNGs desde el icns con `sips`

**4. Editor — errores TypeScript preexistentes**
- `setSelectedElement(null)` — variable que ya no existia (probablemente eliminada en refactor anterior)
- `useRef` importado pero no usado en Inspector.tsx
- Ambos impedian `tauri build`

**5. Android — latencia de uiautomator dump (~2s)**
- Cada `tap(target:)` requiere un dump completo del arbol UI para encontrar el elemento
- Un script de 18 pasos toma ~24 segundos (vs ~5s en iOS)
- **Resuelto**: agente nativo con UiAutomation directa (3-6ms tree, ~150ms tap)

**6. Android — inspector del editor no funciona bien**
- El tree se genera pero el inspector freeze la app al intentar cargar
- **Resuelto parcialmente**: screenshot + tree ahora corren en paralelo (threads Rust)
- **Resuelto**: bug de closure en React — `useCallback` sin `platform` en dependencias causaba que Inspect siempre usara el binario iOS

**7. Android — biometrico en emulador**
- La app Explorea tiene codigo para biometrico + PIN, pero el emulador no tiene fingerprint enrollado
- Solo muestra "Desbloquear con PIN" en vez de ambas opciones
- `BiometricManager.canAuthenticate()` retorna false en el emulador
- **Sin resolver**: necesita `adb -e emu finger touch 1` para enrollar fingerprint

**8. Android — clipboard**
- `getPasteboard()` no tiene API directa en ADB
- `setPasteboard()` usa `adb shell input text` como workaround (no es clipboard real)
- **Sin resolver**: requeriria un helper APK o acceso a clipboard service

**9. Android — Compose elements sin texto en uiautomator**
- Algunos elementos de Jetpack Compose no exponen `text` en el dump de uiautomator
- Los Buttons aparecen como `View` sin texto, el texto esta en un `TextView` hijo
- El tap funciona si buscas por el texto del hijo, pero la jerarquia es confusa
- Workaround: usar `content-desc` (accessibility label) en la app

**10. Android — tabs invisibles despues de navegar**
- Al estar en la pantalla de Capturar, los tabs del bottom bar no aparecen en `uiautomator dump`
- Probablemente el tab bar esta fuera del viewport o uiautomator no lo escanea
- **Sin resolver**: posiblemente un bug de la app demo, no del bridge

### Hallazgos

- El protocolo `DeviceBridge` funciona: misma interfaz, diferente backend, sin duplicar logica
- Los scripts `.auto` son portables — el mismo formato funciona en iOS y Android
- `uiautomator dump` es el cuello de botella en Android (2s vs acceso instantaneo de AXUIElement en iOS)
- El approach de dos binarios separados evita arrastrar frameworks de macOS en el binario Android
- `monkey -p <pkg> -c LAUNCHER 1` es mas confiable que `am start -n` para lanzar apps (no necesitas saber el Activity)

### PRs de la sesion

| PR | Titulo | Estado |
|---|---|---|
| #7 | Limpieza carpetas muertas | Mergeado |
| #8 | Demo iOS/Android reorg | Pendiente |
| #9 | DeviceBridge + AutoCore/AutoLibiOS | Mergeado |
| #10 | Apps demo Android | Mergeado |
| #11 | AdbBridge + docs | Mergeado |
| #12 | Editor con soporte Android | Pendiente |

## Sesion 2026-04-03 — Agente Android nativo

### Contexto

El AdbBridge implementado ayer funcionaba pero era inaceptablemente lento: 2100ms por tap. Decidimos investigar con rigor (como hicimos con la camara iOS) en vez de aceptar la primera solucion.

### Investigacion previa (antes de codificar)

**Maestro:** Despliega APK de instrumentacion con UIAutomator2 server. Usa `dadb` (ADB nativo en Kotlin). HTTP/JSON sobre port forward. Tap: ~50-150ms.

**Appium:** Mismo approach (APK servidor), pero con overhead W3C WebDriver. Tap: ~50-200ms.

**scrcpy:** JAR via `app_process`, `InputManager` via reflexion, protocolo binario sobre socket. Input: <5ms. Pero no tiene acceso a UI tree.

**AccessibilityService vs Instrumentation:** Evaluamos ambos. Instrumentation gano por `injectInputEvent()` (1-3ms) vs `dispatchGesture()` (10-50ms) y soporte de key events.

**Hallazgo clave:** Nadie rapido usa `uiautomator dump`. Todos mantienen un proceso vivo con acceso directo a `UiAutomation`.

### Implementacion

4 archivos Kotlin, ~300 lineas totales:

| Archivo | Responsabilidad |
|---|---|
| `AgentInstrumentation.kt` | Entry point, obtiene UiAutomation, lanza server |
| `SocketServer.kt` | LocalServerSocket, command dispatch, JSON protocol |
| `TreeSerializer.kt` | AccessibilityNodeInfo → JSON (formato compartido con iOS) |
| `InputInjector.kt` | injectInputEvent para tap/swipe/type/keyevent |

### Protocolo

JSON sobre LocalSocket (abstract Unix domain socket), una linea por mensaje:
```
→ {"method":"ping"}
← {"result":"pong","api":36}

→ {"method":"tap","params":{"target":"Login"}}  
← {"result":{"success":true,"x":540,"y":1200}}
```

Conexion desde host: `adb forward tcp:9008 localabstract:autopilot`

### Resultados

| Operacion | uiautomator dump (viejo) | Agente socket (nuevo) | Mejora |
|---|---|---|---|
| Ping | 67ms | 0ms | ∞ |
| Tree (cold) | 2000ms | 315ms | 6x |
| Tree (warm) | 2000ms | 3-6ms | 330-660x |
| Tap por label | 2100ms | 75-171ms | 12-28x |

### Validacion de datos

Comparamos arboles del metodo viejo y nuevo en la misma pantalla (auth screen de Explorea). Resultado: **identicos**. Mismos nodos, roles, textos, coordenadas, jerarquia. diff retorna solo la linea de tiempo del viejo.

### Tropiezo: findAccessibilityNodeInfosByText() y Compose

La API del framework Android para buscar nodos por texto (`findAccessibilityNodeInfosByText()`) retorna lista vacia en apps de Jetpack Compose. El tree muestra los nodos con texto, pero la API de busqueda no los ve.

Causa: Compose genera su arbol de accesibilidad via `SemanticsNode`, no via `View` system. La API del framework busca en el View hierarchy.

Solucion: busqueda recursiva manual con `getChild(i)` + comparacion de `getText()` y `getContentDescription()`. Dos pasadas: exacto primero, contains despues.

### Prueba end-to-end

Flujo completo via socket — auth de Explorea:
1. `ping` → pong (0ms)
2. `tree` → arbol con "Desbloquear con PIN" (6ms)
3. `tap "Desbloquear con PIN"` → abre PIN pad (110ms)
4. `tap "1"`, `tap "2"`, `tap "3"`, `tap "4"` → cada uno ~75-158ms
5. `tree` → Home screen con "Aventura", "Gastronomia", entries (10ms)
6. `swipe up` → scroll (834ms, incluye animacion)

Todo funciono en el primer intento. La diferencia con la camara iOS (10 intentos): esta vez investigamos antes de codificar.

### Archivos creados

```
agent/
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       └── kotlin/dev/autopilot/agent/
│           ├── AgentInstrumentation.kt
│           ├── SocketServer.kt
│           ├── TreeSerializer.kt
│           └── InputInjector.kt
├── build.gradle.kts
├── settings.gradle.kts
├── gradle.properties
└── gradlew
```

APK debug: ~200KB. Compila en 1 segundo (incremental).

### Integración AgentBridge en el CLI

Después de validar el agente, conectamos el CLI `auto-android` al socket:

**Cambios:**
- `AdbBridge` renombrado a `AdbLegacyBridge` (archivado, no eliminado)
- Nuevo `AgentBridge`: habla con el agente via TCP socket localhost:9008
- CLI usa `AgentBridge` por defecto, `--legacy` para el bridge viejo
- Los comandos de UI (tree, tap, type, swipe) pasan por socket
- Los comandos de control (launch, terminate, install, screenshot) siguen por adb

**Benchmarks end-to-end (CLI completo, no solo agente):**

| Operacion | Legacy | AgentBridge | Mejora |
|---|---|---|---|
| Tree | 2397ms | 29ms | 82x |
| Tap | ~2100ms | 123-286ms | 8-17x |
| waitFor | ~2000ms | 300ms | 7x |
| exists | ~2000ms | 306ms | 7x |

**Tropiezo:** El socket Swift inicialmente hacia `shutdown(SHUT_WR)` después de enviar el comando, lo que cerraba la conexión antes de recibir respuestas grandes (como tree). Solución: leer hasta `\n` sin cerrar el write side.

### Editor — Fix Inspect Android

**Problema:** El botón Inspect del editor siempre ejecutaba `auto` (iOS) aunque el toggle mostraba Android. Error: "No simulator window found".

**Causa raiz:** Bug de closure en React. `refreshTree` usaba `useCallback` con dependencias `[appendOutput]` pero sin `platform`. El closure capturaba `platform = "ios"` del primer render y nunca se actualizaba al cambiar el toggle.

**Fix:**
- `useCallback` de `refreshTree`: agregar `platform` a dependencias
- `useCallback` de `runScript`: agregar `platform` a dependencias
- Backend Rust: screenshot y tree ahora corren en paralelo (threads) para reducir latencia del Inspect
- Debug logs via archivo (`/tmp/autopilot-debug.log`) porque `eprintln` no es visible en Tauri

**Tropiezo adicional:** Cargo no recompilaba el editor después de editar `lib.rs` con Claude Code. El tool Edit no actualiza el mtime del archivo de forma que cargo lo detecte. Solución: `touch -t` con timestamp futuro para forzar recompilación.

**Resultado:** Inspect funciona en Android — screenshot + tree en ~500ms (paralelo).

### Editor — Element index Android

**Problema:** `get_element_index` devolvia `[]` para Android — sin autocomplete de `$N` en el editor.

**Causa:** El CLI iOS genera indices con `auto index`, pero no existia equivalente en Android.

**Solucion:** `index_from_tree()` en el backend Rust del editor. Genera indices `$N` directamente desde el arbol de accesibilidad. Resuelve nodos genericos "View" (tipicos de Compose) usando el texto de hijos, y omite contenedores sin informacion util (FrameLayout, LinearLayout en profundidad 0-1). Se integro en `get_element_index` e `inspect`.

**Resultado:** Autocomplete de elementos `$N` funciona en Android. El inspector muestra indices clickeables para ambas plataformas.
