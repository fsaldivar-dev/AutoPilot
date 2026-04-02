# Capitulo 3 — La camara virtual

## 10 intentos, 9 fracasos

El Simulador iOS no tiene camara. `AVCaptureDevice.default(.builtInWideAngleCamera, ...)` retorna `nil`. Para una app que escanea QR, toma selfies, o verifica identidad, esto significa que no se puede probar en CI/CD.

Apple no ofrece solucion. Appium tampoco. Maestro tampoco. BrowserStack cobra $400/mes por un servicio cloud que inyecta un modulo propietario en tu app.

Decidimos resolver esto nosotros. Nos tomo 10 intentos.

> **Nota:** El diario de laboratorio completo (crudo, cronologico, con cada comando y cada error) esta en [camera/BITACORA.md](../../camera/BITACORA.md). Este capitulo es la version narrativa.

---

## Intento 1: CMIOExtension (camara virtual macOS)

**Hipotesis:** macOS permite registrar camaras virtuales via CoreMediaIO Extension. Si registramos una camara que envie frames de una imagen, el Simulador la veria como una webcam.

**Que hicimos:** Implementamos CameraProvider, CameraDevice y CameraStream en Swift puro. La extension se embebe en una app contenedora (`AutoPilotCamera.app`). Compilacion exitosa.

**Por que fallo:** Apple bloquea las system extensions sin un entitlement especifico que hay que solicitar manualmente. `OSSystemExtensionRequest` requiere que la app este en `/Applications/`. El modo developer (`systemextensionsctl developer on`) requiere SIP deshabilitado. Y el camino legacy (DAL plugins) fue removido en macOS 15.

**Que aprendimos:** Apple controla el acceso a hardware virtual con mano dura. No hay workaround sin aprobacion explicita.

---

## Intento 2: Webcam del Mac

**Hipotesis:** El Mac tiene FaceTime HD y iPhone via Continuity Camera. Quizas el Simulador las puede ver.

**Que hicimos:** Verificamos con `system_profiler SPCameraDataType`. Las camaras existen. El Simulador tiene `com.apple.display.captureservice` activo.

**Por que fallo:** El Simulador **no mapea** webcams de macOS a `AVCaptureSession` de apps iOS. `simctl privacy grant camera` no cambia nada — no hay hardware de camara que exponer.

**Que aprendimos:** El Simulador no es una VM completa. No virtualiza hardware de camara.

---

## Intento 3: Dylib injection (ObjC)

**Hipotesis:** Si inyectamos una dylib via `DYLD_INSERT_LIBRARIES` que swizzlee `AVCaptureDevice`, `AVCaptureSession` y `AVCapturePhotoOutput`, podemos interceptar todo el pipeline de camara.

**Que funciono:**
- Dylib ObjC compilada para iOS Simulator, cargada exitosamente
- Swizzle de `authorizationStatus` → `.authorized`
- Swizzle de `startRunning` → interceptado, evita crash
- Swizzle de `capturePhoto:delegate:` → interceptado
- Runtime introspection encuentra el selector `didFinishProcessingPhoto` en el delegate

**Por que fallo:** `AVCapturePhoto` tiene `init` marcado `NS_UNAVAILABLE`. No se puede instanciar. Intentamos:
- `objc_msgSend(alloc, init)` → crash por ARM64 PAC (Pointer Authentication Code)
- Subclase via `objc_allocateClassPair` → PAC valida el objeto interno
- `object_getIvar` para acceder closure Swift → Swift closures no son ObjC blocks, distinta calling convention → `EXC_BAD_ACCESS`

**Que aprendimos:** ObjC runtime puede interceptar llamadas pero no puede crear objetos Swift validos ni invocar closures Swift. La barrera entre ObjC y Swift es mas profunda de lo que parece.

---

## Intento 4: Variables de entorno

**Resultado:** Funciona. Pero requiere modificar el codigo de la app.

11 lineas en la app leen `AUTOPILOT_CAMERA_IMAGE` del environment y retornan esa imagen cuando se llama `capturePhoto`. Simple, determinista, rapido.

**Hallazgo inesperado:** `/tmp/` del Simulador NO es `/tmp/` del Mac — tienen filesystems separados. Pero el proceso de la app SI corre como proceso macOS y SI puede leer rutas absolutas del Mac.

**Limitacion:** Solo funciona si controlas el codigo. Para apps de terceros, no aplica.

---

## Intento 5: Swift dylib

**Hipotesis:** Si la dylib esta escrita en Swift (no ObjC), puede crear objetos Swift validos y llamar closures directamente.

**Que funciono:** El swizzle de todos los metodos. La carga de imagen. La interceptacion de `capturePhoto`.

**Por que fallo:** Acceder al ivar `onPhotoCaptured` del CameraManager via `ivar_getOffset` + `assumingMemoryBound(to:)` crashea. Las closures Swift en memoria no son function pointers simples — tienen contexto capturado + metadata que no se puede reinterpretar como `(UIImage) -> Void`.

**Que aprendimos:** No es PAC. Es la ABI de Swift closures. El layout en memoria de una closure Swift es opaco y no esta documentado publicamente.

---

## Intento 6: Package con callback registrado

**Resultado:** Funciona. La app necesita 1 linea.

En vez de buscar el callback via introspection, la app registra `AutoPilotCamera.onPhotoCaptured = callback`. El swizzle lo invoca directamente. Probado end-to-end: imagen inyectada, "Fotos capturadas 1".

**Limitacion:** Requiere que la app dependa del package. No funciona con apps de terceros.

---

## Intento 7: Pre-build script

**Hipotesis:** Un script de Xcode pre-build reemplaza `AVCaptureDevice` → `AutoPilotCaptureDevice` en todos los archivos fuente. Post-build restaura.

**Que funciono:** Los archivos del proyecto principal se reemplazan correctamente.

**Por que fallo:** No alcanza dependencias SPM. Solo modifica archivos del workspace. Ademas, conflictos de tipos: `AVCaptureDevice.default(for:)` retorna el tipo real, pero nuestro wrapper espera otro tipo.

---

## Intento 8: VFS overlay + module map

**Hipotesis:** Usar un Virtual Filesystem overlay para reemplazar los headers de AVFoundation con versiones custom que incluyan nuestras clases mock.

**Por que fallo:** Los headers de AVFoundation son interdependientes. Simplificar un header rompe otros — tipos como `AVCaptureConnection` faltan y causan errores en cadena. Mantener headers custom completos es inviable por la superficie de API.

---

## Intento 9: force_load + #undef AV_INIT_UNAVAILABLE

**Resultado:** FUNCIONA. Sin modificar la app.

Este fue el momento eureka.

El problema central de los intentos 3 y 5 era que `AVCapturePhoto` tiene `init` marcado como no disponible. Pero esa restriccion es *solo de compilador*, no de runtime. El macro `AV_INIT_UNAVAILABLE` esta definido en `AVBase.h`.

La solucion:

```objc
// Importar AVBase.h primero (define AV_INIT_UNAVAILABLE)
#import <AVFoundation/AVBase.h>

// Eliminar la restriccion
#undef AV_INIT_UNAVAILABLE
#define AV_INIT_UNAVAILABLE

// Ahora importar AVFoundation — init de AVCapturePhoto esta disponible
#import <AVFoundation/AVFoundation.h>

// Esto funciona:
AVCapturePhoto *photo = [[AVCapturePhoto alloc] init];
```

Con init disponible, podemos crear instancias reales de `AVCapturePhoto` y guardar datos via `objc_setAssociatedObject` — sin tocar ivars internos, sin PAC issues.

El codigo se compila a una static library de ~28KB y se inyecta via `-force_load` en el `OTHER_LDFLAGS` de xcodebuild. El constructor `__attribute__((constructor))` swizzlea ~25 metodos al cargar.

**Metodos swizzleados:**
- AVCaptureDevice: authorizationStatus, requestAccess, defaultDevice (2 variantes)
- AVCaptureDeviceInput: initWithDevice, deviceInputWithDevice
- AVCaptureSession: startRunning, stopRunning, isRunning, canAdd/add/remove Input/Output, begin/commitConfiguration, inputs, outputs
- AVCapturePhotoOutput: capturePhoto:delegate:
- AVCapturePhoto: fileDataRepresentation, CGImageRepresentation, timestamp, photoCount, isRawPhoto
- AVCaptureMetadataOutput: setMetadataObjectsDelegate, setMetadataObjectTypes
- AVCaptureVideoPreviewLayer: setSession (muestra preview con labels "LIVE" + "AutoPilot | Mock Camera")

**Gotcha:** `class_addMethod` vs `method_setImplementation`. Si el metodo esta heredado (no directamente en la clase), `method_setImplementation` modifica la *superclase*. `class_addMethod` lo agrega directamente a la subclase. Esto causo bugs sutiles hasta que lo entendimos.

**Gotcha:** Xcode 26 requiere `ENABLE_DEBUG_DYLIB=NO` para que `-force_load` funcione en el binario principal.

---

## Intento 10: DYLD_INSERT_LIBRARIES (sin recompilar)

**Resultado:** FUNCIONA. Sin proyecto Xcode. Con hot-swap.

El mismo codigo ObjC del intento 9 se compila como dylib en vez de static library, se cachea, y se inyecta via `DYLD_INSERT_LIBRARIES` al lanzar la app.

Este intento se convirtio en un capitulo completo: [Capitulo 4 — Inyeccion sin recompilar](04-inyeccion-sin-recompilar.md).

---

## Mapa de intentos

```
Intento  Enfoque                          Resultado
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1      CMIOExtension                    Bloqueado (entitlement Apple)
  2      Webcam del Mac                   No funciona (no hay mapeo)
  3      Dylib ObjC                       Parcial (PAC bloquea objetos)
  4      Variables de entorno             Funciona (requiere modificar app)
  5      Swift dylib                      Parcial (ABI closures)
  6      Package + callback               Funciona (requiere 1 linea)
  7      Pre-build script                 Parcial (no alcanza SPM deps)
  8      VFS overlay + module map         No funciona (headers rotos)
  9      force_load + #undef              FUNCIONA (sin modificar app) ←
  10     DYLD_INSERT_LIBRARIES            FUNCIONA (sin recompilar)   ←
```

## Que aprendimos (meta-lecciones)

1. **Las restricciones de compilador no son restricciones de runtime.** `AV_INIT_UNAVAILABLE` es un macro que desaparece despues de compilar. El runtime no sabe que init estaba "prohibido".

2. **Associated objects son la herramienta correcta.** En vez de tocar ivars internos (que rompe con PAC), `objc_setAssociatedObject` permite guardar datos en cualquier objeto sin conocer su layout interno.

3. **Las ABI boundaries son reales.** ObjC y Swift comparten el runtime de Objective-C, pero las closures de Swift y los layouts de memoria son opacos. No asumas que puedes cruzar la frontera con casting.

4. **Apple protege el hardware virtual.** CMIOExtension, DAL plugins, webcam mapping — todo requiere permisos especiales o esta deprecado. La solucion fue no virtualizar hardware, sino interceptar el software.

5. **Los intentos fallidos no son tiempo perdido.** Cada intento nos ensenó algo que uso el siguiente. El intento 3 nos enseno el swizzle, el 5 nos enseno los limites de Swift ABI, el 9 resolvio el problema de init — sin los 8 fracasos anteriores, el 9 no habria existido.

---

*Anterior: [Capitulo 2 — Arquitectura](02-arquitectura.md) | Siguiente: [Capitulo 4 — Inyeccion sin recompilar](04-inyeccion-sin-recompilar.md)*
