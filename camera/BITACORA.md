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

### Resumen de archivos

| Archivo | Proposito | Estado |
|---|---|---|
| `camera/CameraExtension/` | CMIOExtension Swift | Completo, bloqueado por entitlement |
| `camera/AutoPilotCamera/` | App contenedora | Completo, bloqueado por entitlement |
| `camera/CameraInject/AutoPilotCamera.m` | Dylib ObjC swizzle | Funciona parcialmente (intercepta, no inyecta) |
| `cli/Sources/AutoLib/SimulatorBridge.swift` | `cameraStart/Feed/Stop/Status` + `launchApp --env` | Funcional |
| `cli/Sources/CLI/main.swift` | `auto camera` + `auto launch --env` | Funcional |
| `docs/ios/VARIABLES_ENTORNO.md` | Spec de env vars | Completa |
| `Demo/.../CaptureView.swift` | +5 lineas env var camara | Funcional, probado |
| `Demo/.../QRScannerView.swift` | +5 lineas env var QR | Funcional, no probado aun |
