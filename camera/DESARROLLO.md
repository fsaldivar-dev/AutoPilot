# Camara Virtual — Notas de Desarrollo

## Estado Actual

El codigo de la CMIOExtension esta completo y compila correctamente. La instalacion esta bloqueada porque macOS requiere el entitlement `com.apple.developer.system-extension.install` aprobado por Apple para instalar system extensions con SIP habilitado.

## Tropiezos Encontrados

### 1. DAL Plugin (descartado)

**Enfoque inicial:** CoreMediaIO DAL (Device Abstraction Layer) plugin — un bundle `.plugin` en `/Library/CoreMediaIO/Plug-Ins/DAL/`.

**Resultado:** Los DAL plugins estan **deprecados desde macOS 14** y **removidos en macOS 15** (Darwin 25.x). No es una opcion viable.

### 2. CMIOExtension como System Extension

**Enfoque correcto:** CMIOExtension (macOS 12.3+), Swift puro, sin dependencias.

**Problema 1 — Ubicacion de la app:**
```
Error: App containing System Extension to be activated must be in 
/Applications folder.
```
La app contenedora debe estar en `/Applications/`, no en DerivedData. Se resuelve copiando la app.

**Problema 2 — Extension no encontrada:**
```
Error: Extension not found in App bundle. Unable to find any matched 
extension with identifier: dev.autopilot.camera.extension
```
La extension esta correctamente embedida en `Contents/Library/SystemExtensions/`, con bundle ID, team ID, y NSExtensionPointIdentifier correctos. El problema es que sin el entitlement aprobado por Apple, `OSSystemExtensionManager` no puede activar la extension.

**Problema 3 — SIP bloquea developer mode:**
```
systemextensionsctl developer on
→ Error: Cannot be used if System Integrity Protection is enabled.
```
Sin deshabilitar SIP, no se puede usar el modo developer para system extensions.

### 3. Hosting CMIOExtensionProvider en la app

**Intento:** Ejecutar `CMIOExtensionProvider.startService()` directamente desde la app (sin system extension).

**Resultado:** `startService()` solo funciona cuando se ejecuta desde el contexto de una system extension. Desde una app normal, el provider no se registra y la camara no aparece en el sistema.

## Solucion: Solicitar Entitlement a Apple

### Que se necesita

1. **Entitlement:** `com.apple.developer.system-extension.install`
2. **URL de solicitud:** https://developer.apple.com/contact/request/system-extension/
3. **Tiempo estimado:** 1-4 semanas

### Informacion para la solicitud

| Campo | Valor |
|---|---|
| Team ID | W7DAJUM9J6 |
| App Bundle ID | dev.autopilot.camera |
| Extension Bundle ID | dev.autopilot.camera.extension |
| Tipo de extension | Camera Extension (CMIOExtension) |
| Caso de uso | Camara virtual para automatizacion de pruebas iOS en CI/CD headless. Alimenta imagenes estaticas como feed de camara al Simulador iOS donde no hay webcam fisica. |

### Justificacion tecnica

AutoPilot es una herramienta de automatizacion de pruebas para iOS que necesita simular una camara en entornos CI/CD donde no hay hardware de camara disponible. La CMIOExtension permite:

- Testear funcionalidades que dependen de camara (escaneo QR, captura de documentos, verificacion biometrica)
- Ejecutar pruebas automatizadas en pipelines headless (GitHub Actions, Jenkins, etc.)
- Inyectar imagenes controladas para pruebas deterministas

Sin la camara virtual, estas funcionalidades no se pueden testear en CI/CD.

### Pasos despues de la aprobacion

1. Apple aprueba el entitlement
2. Habilitar en el App ID: https://developer.apple.com/account/resources/identifiers/list
3. Regenerar provisioning profile en Xcode
4. Recompilar y firmar la app
5. Instalar en `/Applications/`
6. Ejecutar → la extension se activa
7. `auto camera start imagen.jpg` funciona

### Alternativa temporal (desarrollo)

Para probar en desarrollo sin esperar la aprobacion:

1. Reiniciar en Recovery Mode (Cmd+R al encender)
2. Terminal → `csrutil disable`
3. Reiniciar normalmente
4. `systemextensionsctl developer on`
5. Ejecutar AutoPilotCamera.app desde `/Applications/`
6. La extension se instala sin restricciones
7. **Volver a habilitar SIP despues:** Recovery Mode → `csrutil enable`

## Tropiezo 4: Dylib injection (DYLD_INSERT_LIBRARIES)

**Enfoque:** Inyectar una dylib ObjC al proceso de la app iOS en el Simulador que haga swizzle de las APIs de camara (AVCaptureDevice, AVCaptureSession, AVCapturePhotoOutput).

**Lo que funciono:**
- La dylib se carga correctamente via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`
- El swizzle de `authorizationStatus(.video) -> .authorized` funciona
- El swizzle de `AVCaptureSession.startRunning()` intercepta correctamente
- El swizzle de `capturePhotoWithSettings:delegate:` intercepta la captura
- Se encontro el selector `didFinishProcessingPhoto` via runtime introspection
- Se encontro el ivar `onPhotoCaptured` del CameraManager

**Lo que NO funciono:**
- `AVCapturePhoto` no se puede instanciar (init marcado unavailable)
- Crear instancia via `objc_msgSend(alloc, init)` falla por Pointer Authentication (PAC) en ARM64
- El objeto creado no tiene estado interno valido — crash en `fileDataRepresentation`
- `object_getIvar` para acceder al closure Swift `onPhotoCaptured` crashea porque Swift closures no son ObjC blocks directamente — tienen distinta calling convention
- Todos los intentos de invocar el closure directamente resultan en `EXC_BAD_ACCESS` con PAC failure

**Conclusion:** El swizzling de AVFoundation funciona para interceptar, pero no para inyectar resultados de vuelta. ARM64 PAC y las diferencias entre Swift closures y ObjC blocks hacen imposible invocar callbacks de la app desde ObjC puro.

### Compilacion de la dylib

```bash
xcrun clang -dynamiclib \
    -framework Foundation -framework UIKit -framework AVFoundation \
    -framework CoreMedia -framework CoreVideo -framework CoreImage \
    -framework CoreGraphics \
    -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) \
    -target arm64-apple-ios26.0-simulator \
    -o libAutoPilotCamera.dylib \
    AutoPilotCamera.m

# Lanzar app con inyeccion
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="/path/to/libAutoPilotCamera.dylib" \
    xcrun simctl launch booted "com.example.app"
```

## Estado actual y plan

### Lo que funciona hoy
- `auto camera start <imagen>` — copia imagen a `/tmp/autopilot-camera-feed.jpg`
- `auto camera feed <imagen>` — actualiza la imagen
- `auto camera stop` / `auto camera status`
- `auto media <imagen>` — inyecta fotos a la galeria (simctl addmedia)
- Dylib se carga y swizzlea exitosamente

### Plan para proxima iteracion
1. **Enfoque galeria:** usar `simctl addmedia` + `simctl privacy grant photos` para inyectar la imagen y que la app la use desde la galeria
2. **Enfoque CMIOExtension:** solicitar entitlement a Apple, cuando aprueben reactivar el codigo existente
3. **Investigar:** como RocketSim logra inyectar frames — puede haber un approach via `FigCaptureSession` hooks que no exploramos

## Arquitectura Final (cuando se apruebe CMIOExtension)

```
Terminal                    /tmp/                   AutoPilotCamera.app
                                                    (CMIOExtension)
auto camera start img.jpg → autopilot-camera-feed.jpg ← Lee imagen
                          → autopilot-camera-active    ← Verifica signal
                                                    → Push CMSampleBuffer
                                                      al Simulador
```

La comunicacion es por archivos — simple, sin IPC complejo, funciona con sandbox.
