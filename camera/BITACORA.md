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
