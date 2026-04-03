# AutoPilot — Guia de Desarrollo

## Filosofia

- Swift puro, sin dependencias externas, sin Python, sin runtimes
- Dos binarios CLI: `auto` (iOS) y `auto-android` (Android)
- Protocolo `DeviceBridge` compartido — misma interfaz, diferente backend
- Scripts `.auto` como lenguaje principal de automatizacion
- El mismo script funciona en iOS y Android (cambias el binario, no el script)
- Documentacion en español

## Stack

- **CLI**: Swift 5.9+, macOS 13+, SPM
- **Editor**: Tauri 2 + React + TypeScript + Monaco
- **CI/CD**: GitHub Actions, macos-15 runner

## Estructura del proyecto

```
cli/Sources/AutoCore/    → Compartido: DeviceBridge, AgentBridge, AdbLegacyBridge, CommandDispatcher, ScriptParser
cli/Sources/AutoLibiOS/  → iOS: SimulatorBridge, ElementIndex, TargetResolver, UIStabilizer, AXDebug
cli/Sources/CLI/         → Binario `auto` (iOS)
cli/Sources/CLIAndroid/  → Binario `auto-android` (Android)
editor/src/              → Frontend React del editor
editor/src-tauri/        → Backend Rust del editor
Demo/iOS/                → Apps de demo iOS (CameraTestApp, Test Automatitacion)
Demo/Android/            → Apps de demo Android (CameraTestApp, TestAutomatitacion)
scripts/examples/        → Scripts .auto de ejemplo (iOS + Android)
docs/                    → Documentacion por modulo
```

## Workflow de desarrollo

### 1. Planear
- Usar `/feature-dev` para features nuevas (7 fases: discovery, explore, questions, architecture, implement, review, summary)
- Para cambios pequenos, ir directo a implementar

### 2. Implementar
- Swift: sin dependencias, sin frameworks externos
- Codigo compartido va en `AutoCore/`, iOS-only en `AutoLibiOS/`
- Nuevos comandos cross-platform: implementar en `DeviceBridge` protocolo
- React/TypeScript: Monaco para editor, Tauri para desktop
- Seguir patrones existentes (Process + xcrun para iOS, Process + adb para Android)

### 3. Probar
- Compilar CLI: `cd cli && swift build` (compila ambos binarios)
- Copiar binario iOS: `cp .build/debug/auto ../auto`
- Probar iOS: `./auto run scripts/examples/camera-test.auto`
- Probar Android: `.build/debug/auto-android run scripts/examples/android-login.auto`
- Requisitos Android: emulador corriendo (`adb devices`), ANDROID_HOME configurado
- Para UI del editor: `cd editor && npm run tauri dev`
- Para CI: push a main y verificar GitHub Actions
- Tomar screenshots como evidencia

### 4. Revisar
- Correr `/simplify` para detectar codigo duplicado o ineficiente
- Correr `/code-review` antes de PR para validar calidad
- Verificar que no hay archivos muertos, ramas mergeadas sin borrar

### 5. Commitear
- Usar `/commit` para commits con mensaje consistente
- Formato: descripcion corta + cuerpo con contexto
- No commitear archivos sensibles (.env, credentials)
- No commitear archivos temporales (temp/, screenshots de debug)

### 6. PR
- Usar `/commit-push-pr` para crear PR completo
- PR debe incluir: summary, test plan con checkmarks, tabla de archivos
- Correr `/code-review --comment` para agregar revision automatica

### 7. Documentar
- Usar `/docs` para documentar cambios como libro tecnico
- Actualizar `docs/camera/BITACORA.md` con hallazgos de cada sesion
- Actualizar `README.md` si hay features nuevos
- Actualizar memoria en `.claude/projects/.../memory/`

### 8. Limpiar
- `/clean_gone` para borrar ramas locales ya mergeadas
- Verificar que `.autopilot` no tiene paths absolutos de tu maquina

## Convenciones de codigo

### Swift (CLI)
- `DeviceBridge` protocolo — 22 metodos que iOS y Android implementan
- `SimulatorBridge` (iOS): AXUIElement + CGEvent + xcrun simctl
- `AgentBridge` (Android, default): socket TCP al agente nativo con UiAutomation directa
- `AdbLegacyBridge` (Android, `--legacy`): adb shell + uiautomator dump (archivado para benchmarks)
- `CommandDispatcher` — logica compartida de comandos
- Errores tipados con `BridgeError` enum
- `public` solo para lo que necesita el CLI, `private` para el resto

### TypeScript (Editor)
- Componentes funcionales con hooks
- `invoke()` de Tauri para llamar al backend Rust
- `useRef` para estado que Monaco necesita en closures
- Tema oscuro "autopilot" basado en Tokyo Night

### ObjC (Camera Mock)
- Codigo embebido como string en MockHeaders.swift
- Swizzle via `class_addMethod` / `method_setImplementation`
- Associated objects para datos sin tocar ivars
- `__attribute__((constructor))` para auto-init

## Testing

### Scripts .auto
```bash
ping                    # Verificar conexion
tap Elemento            # Tap por label
tap Camera[2]           # Segundo duplicado
tap 1,2,3,4,Confirmar  # Multi-tap
waitFor "texto" 10     # Esperar elemento
screenshot file.png     # Evidencia
```

### CI/CD
- Workflow `CI` — build + test + release
- Workflow `E2E Tests` — Face ID + pasteboard + camera mock
- Todo debe pasar verde antes de mergear

### Camera mock
```bash
auto config project App.xcodeproj
auto config scheme App
auto config bundle com.example.app
auto config image foto.jpg
auto build
auto launch
```

## Limitaciones conocidas

### iOS
- SwiftUI NavigationBar buttons no se exponen via macOS AX (AXChildren=[0])
- El preview de camara es imagen estatica (sin feed en tiempo real)
- `ENABLE_DEBUG_DYLIB=NO` necesario en Xcode 26 para force_load

### Android
- Con `--legacy`: `uiautomator dump` toma 1-2 segundos (el AgentBridge default no tiene este problema)
- Clipboard read no soportado via ADB (solo write como workaround)
- Camera mock no implementado aun en Android
- Element index `$N` en Android se genera en el editor (Rust), no en el CLI — `auto-android index` aun no existe

### General
- El editor necesita Rust toolchain instalado (`rustup`)
