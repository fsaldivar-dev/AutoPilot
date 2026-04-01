# Variables de Entorno para Automatizacion

## Problema

El Simulador iOS no tiene acceso a camara fisica. En CI/CD headless no hay webcam. Las APIs de `AVCaptureSession` fallan porque no hay fuente de video.

**Intentos fallidos:**
- CMIOExtension: requiere entitlement de Apple (pendiente)
- DAL plugin: removido en macOS 15
- Dylib injection: ARM64 PAC impide crear AVCapturePhoto falso
- Webcam del Mac: el Simulador no la mapea a AVCaptureSession

## Solucion: Variables de Entorno

AutoPilot inyecta variables de entorno al lanzar la app. La app las detecta y usa datos mock en vez del hardware real. Esto requiere un cambio minimo en la app (3-5 lineas) que no afecta el flujo normal en dispositivos fisicos.

### Variables disponibles

| Variable | Valor | Efecto |
|---|---|---|
| `AUTOPILOT_CAMERA_IMAGE` | Ruta a imagen (ej: `/tmp/foto.jpg`) | `capturePhoto()` retorna esta imagen en vez de capturar del hardware |
| `AUTOPILOT_QR_CODE` | Contenido del QR (ej: `https://ejemplo.com`) | El scanner QR retorna este valor en vez de escanear |

### Uso desde AutoPilot

```bash
# Inyectar imagen para camara
auto launch com.example.app --env AUTOPILOT_CAMERA_IMAGE=/tmp/foto.jpg

# Inyectar resultado de QR
auto launch com.example.app --env AUTOPILOT_QR_CODE="https://ejemplo.com"

# Multiples variables
auto launch com.example.app --env AUTOPILOT_CAMERA_IMAGE=/tmp/foto.jpg --env AUTOPILOT_QR_CODE="https://ejemplo.com"
```

### Implementacion en la app (cambio minimo)

#### Camara — CameraManager

```swift
// ANTES (sin cambios para dispositivo fisico):
func capturePhoto() {
    sessionQueue.async { [self] in
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// DESPUES (3 lineas agregadas):
func capturePhoto() {
    // AutoPilot: si hay imagen inyectada, usarla en vez de la camara
    if let path = ProcessInfo.processInfo.environment["AUTOPILOT_CAMERA_IMAGE"],
       let image = UIImage(contentsOfFile: path) {
        onPhotoCaptured?(image)
        return
    }
    sessionQueue.async { [self] in
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}
```

#### QR Scanner

```swift
// Agregar al inicio del scanner, antes de configurar AVCaptureSession:
if let code = ProcessInfo.processInfo.environment["AUTOPILOT_QR_CODE"] {
    onCodeScanned?(code)
    return
}
```

### Por que este enfoque

1. **Minimo impacto:** 3-5 lineas por feature, no afecta dispositivos fisicos
2. **Sin dependencias:** usa `ProcessInfo` que es Foundation puro
3. **Determinista:** la imagen/QR es siempre la misma, tests repetibles
4. **CI/CD friendly:** `auto launch --env` funciona en headless
5. **Documentado:** el cambio es explicito y rastreable

### Como funciona internamente

```
Terminal                          Simulador
auto launch app                   
  --env AUTOPILOT_CAMERA_IMAGE    
  =/tmp/foto.jpg                  
         |                        
         v                        
SIMCTL_CHILD_AUTOPILOT_CAMERA_IMAGE=/tmp/foto.jpg
xcrun simctl launch booted app    
         |                        
         v                        
         +--> app arranca con     
              env var seteada     
              |                   
              v                   
              capturePhoto() -->  
              detecta env var --> 
              carga imagen -->    
              onPhotoCaptured()   
```

### Convenciones

- Todas las variables empiezan con `AUTOPILOT_`
- Solo se leen, nunca se escriben
- Si la variable no existe, el flujo normal continua sin cambios
- Las rutas son absolutas dentro del filesystem del Simulador
- Para inyectar archivos al Simulador: `auto media <archivo>` o copiar a `/tmp/`
