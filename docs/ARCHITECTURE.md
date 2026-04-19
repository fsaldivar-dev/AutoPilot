# AutoPilot — Arquitectura actual

**Estado a:** 2026-04-19 (tras merge de PR #110)

Este documento describe **cómo está hecho** el sistema hoy. Para entender **por qué** está hecho así, ver [HISTORY.md](HISTORY.md) y [POSTMORTEMS.md](POSTMORTEMS.md).

---

## Visión alto nivel

```
┌──────────────────────────────────────────────────────────┐
│                   scripts/*.auto                          │
│         (lenguaje de automatización del user)             │
└─────────────────────────┬────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│  auto  (iOS)         auto-android  (Android)              │
│  CLI launchers delgados (~500 LOC cada uno)               │
└─────────┬────────────────────────────┬───────────────────┘
          │                            │
          ▼                            ▼
┌──────────────────────────────────────────────────────────┐
│          ActionRouter + CapabilityRegistry                │
│  (ARD-001 — Command + Capability Discovery)               │
└──┬──────────────────────────────────────────┬────────────┘
   │                                           │
   ▼ iOS backends                              ▼ Android backends
 AXBackend                                   AgentBackend
 XCUIBackend                                 AdbBackend
 SimCtlBackend
 MediaBackend
   │                                           │
   ▼ delegates                                 ▼ delegates
 SimulatorBridge                              AgentBridge
 (+AXEngine, +SimCtlEngine,                   AdbLegacyBridge
  +MediaEngine como extensions)
   │                                           │
   ▼                                           ▼
 iOS Simulator                               Android emulator / device
 (AX macOS + xcrun simctl                    (adb + UiAutomation via
  + XCTest runner via autopilotd)             instrumentation APK)
```

---

## Paradigma ARD-001 — Command + Capability Discovery

El corazón de la arquitectura. En lugar de un `DeviceBridge` monolítico de 53 métodos, cada acción es un **valor** que viaja por el sistema, y cada backend declara **qué sabe hacer**.

```swift
// 1. Comando como dato
enum Action {
    case tap(target: String)
    case type(String)
    case screenshot(path: String)
    // ... 40+ más
}

// 2. Backend declara capabilities
protocol Backend {
    var capabilities: Set<ActionKind> { get }
    func execute(_ action: Action) async throws -> ActionResult
}

// 3. Router rutea por capability con escalation
actor ActionRouter {
    func execute(_ action: Action) async throws -> ActionResult {
        // Consulta registry → primer backend capaz
        // Si lanza .elementNotFound → escala al siguiente
    }
}
```

**Propiedades:**
- Cada backend implementa **solo lo que sabe** — no más `notImplemented()`.
- Agregar un nuevo backend (Maestro, WebDriver, etc.) = 1 archivo + registro.
- El **orden de registro** define el escalation path.
- CLIs ignoran qué backend ejecuta — solo arman Actions.

Ver [rfc/ARD-001-backend-pattern.md](rfc/ARD-001-backend-pattern.md).

---

## Estructura de directorios

```
cli/Sources/
├── AutoCore/                   ← compartido iOS/Android
│   ├── Backend.swift           Action, ActionKind, ActionResult, Backend protocol
│   ├── ActionRouter.swift      actor con escalation
│   ├── CapabilityRegistry.swift actor thread-safe
│   ├── ConstrainedBackend.swift wrapper que limita capabilities de un delegate
│   ├── LegacyBridgeAdapter.swift adapter temporal DeviceBridge → Backend
│   ├── DeviceBridge.swift      protocolo legacy (deprecado pero alive)
│   ├── DeviceResolver.swift    protocolo bootstrap
│   ├── CommandDispatcher.swift switch de 51 comandos del script
│   ├── ScriptParser.swift      tokenizer + parseCommand
│   ├── AgentBridge.swift       Android agent client (TCP)
│   ├── AdbLegacyBridge.swift   Android adb fallback
│   ├── AgentBackend.swift      factory Android primary
│   ├── AdbBackend.swift        factory Android fallback
│   ├── AndroidDeviceResolver.swift
│   ├── AndroidSetup.swift      bootstrap idempotente
│   ├── AndroidTapEnhancement.swift  $N, label[N], Compose clickable
│   ├── AndroidListCommand.swift typed listing via router
│   ├── AndroidCameraCommand.swift  JVMTI camera mock
│   └── ... (doctors, usage, helpers)
│
├── AutoLibiOS/                 ← iOS-specific
│   ├── SimulatorBridge.swift            core (677 LOC: gestures + input + state)
│   ├── SimulatorBridge+AXEngine.swift   521 LOC: AX queries, element search
│   ├── SimulatorBridge+SimCtlEngine.swift 677 LOC: simctl + biometry + files
│   ├── SimulatorBridge+MediaEngine.swift 200 LOC: screenshot + recording + camera
│   ├── AXBackend.swift         factory — capabilities AX iOS
│   ├── XCUIBackend.swift       factory — capabilities XCUI (SwiftUI deep)
│   ├── SimCtlBackend.swift     factory — capabilities simctl
│   ├── MediaBackend.swift      factory — capabilities media
│   ├── iOSDeviceResolver.swift bootstrap iOS
│   ├── iOSSetup.swift          bootstrap idempotente (sim + runner + daemon)
│   ├── iOSTapEnhancement.swift $N, within, label[N], multi-tap
│   ├── iOSLaunchEnhancement.swift launch + camera mock + DylibInjector
│   ├── XCUIBridge.swift        cliente TCP del runner XCTest
│   ├── HybridBridge.swift      legacy — antes del router (deprecado, aún usado por AUTO_BRIDGE=hybrid)
│   └── ... (doctors, runner installer, recording session)
│
├── CLI/                        ← binario auto (iOS)
│   └── main.swift              483 LOC — thin launcher
│
├── CLIAndroid/                 ← binario auto-android
│   └── main.swift              255 LOC — thin launcher
│
└── Daemon/                     ← binario autopilotd (XCTest runner lifecycle)
    ├── main.swift
    ├── DaemonServer.swift      socket UNIX
    └── RunnerLifecycle.swift   xcodebuild test-without-building
```

---

## Backends iOS — capabilities declaradas

| Backend | Capabilities | Notas |
|---------|--------------|-------|
| **AXBackend** | `tap`, `doubleTap`, `longPress`, `clear`, `scroll`, `swipe`, `tree`, `search`, `elementAt`, `typeText`, `pressKey`, `hideKeyboard`, `eraseText`, `copyTextFrom`, `existsFast`, `viewport` | Fast path, macOS AX. Ciego a SwiftUI NavBar. |
| **XCUIBackend** | Subset de AX + `tap` en SwiftUI NavBar | Warm ~430ms/tap. Cold boot 10-45s. Fallback automático del router cuando AX lanza `elementNotFound`. |
| **SimCtlBackend** | `launchApp`, `terminateApp`, `installApp`, `uninstallApp`, `listDevices`, `bootDevice`, `shutdownDevice`, `getBootedDeviceId`, `setPermission`, `getLogs`, `biometric*`, `clearState`, `resetKeychain`, `setLocation`, `setAppearance`, `lockDevice`, `unlockDevice`, `rotate`, `openURL`, `setPasteboard`, `getPasteboard`, `pushFile`, `pullFile`, `pressKey`, `hideKeyboard`, `eraseText` | Todo lo que necesita `xcrun simctl` o AppleScript al menú Simulator. |
| **MediaBackend** | `screenshot`, `addMedia`, `startRecording`, `stopRecording` | Aislado por state machine de recording. |

**Orden de registro en `iOSDeviceResolver`:**

```swift
registry.register(AXBackend)       // 1. fast
registry.register(XCUIBackend)     // 2. escalation para .elementNotFound de AX
registry.register(SimCtlBackend)   // 3. device lifecycle
registry.register(MediaBackend)    // 4. screenshot / recording
```

---

## Backends Android — capabilities declaradas

| Backend | Capabilities | Notas |
|---------|--------------|-------|
| **AgentBackend** | Superset completo (tap, tree, typeText, swipe, installApp, screenshot, etc.) | Via TCP socket a agente UiAutomation en device/emulator. ~30-50ms por comando. |
| **AdbBackend** | Subset sin camera, sin recording, sin biometric enroll | Fallback lento via `adb shell`. Activado con `--legacy`. |

**Orden en `AndroidDeviceResolver`:**
- Sin `--legacy`: solo `AgentBackend` registrado
- Con `--legacy`: solo `AdbBackend` registrado

No hay escalation en Android — cada modo es exclusivo.

---

## Flujo de ejecución — `auto run script.auto`

```
1. CLI reads script
   ↓
2. ScriptParser → [ParsedCommand]
   ↓
3. Por cada comando:
   ↓
4. runAsync { try await router.execute(.tap(target: "Login")) }
   ↓
5. ActionRouter busca en CapabilityRegistry backends con .tap
   ↓
6. Primer backend (AXBackend) ejecuta
   ├── Success → ActionResult.void → print, siguiente comando
   └── BridgeError.elementNotFound → router pasa al siguiente (XCUIBackend)
        └── Success → print, siguiente comando
        └── Error final → exit 1
   ↓
7. Stabilizer ajusta timing entre comandos (iOS only)
```

---

## Interacciones cross-componente

### iOS en simulator con XCUI runner

```
auto (CLI process)
   │
   │ 1. Spawnea autopilotd como daemon (sidecar)
   ▼
autopilotd (Unix socket /tmp/autopilot-<UDID>.sock)
   │
   │ 2. Arranca runner XCTest
   ▼
xcodebuild test-without-building
   │
   │ 3. Lanza AutoPilotRunner.app dentro del Simulator
   ▼
iOS Simulator
   │
   │ 4. Runner abre TCP loopback en 127.0.0.1:22087
   ▼
XCUIBridge (dentro de auto)
   │
   │ 5. TCP directo al runner (NO al daemon proxy)
   ▼
Runner responde XCUIElement queries

           Fallback si TCP fails →
           Via daemon Unix socket →
           Daemon re-spawnea runner →
           TCP vuelve a estar UP
```

**Optimización:** el fast-path (TCP directo) ahorra el Unix socket roundtrip via daemon, reduciendo latencia de ~1500ms → ~430ms warm.

### Android con agente nativo

```
auto-android (CLI process)
   │
   │ 1. adb forward tcp:9008 localabstract:autopilot
   ▼
adb → Android device/emulator
   │
   │ 2. am instrument -w dev.autopilot.agent/.AgentInstrumentation
   ▼
agent.apk (dentro del proceso instrumentation del device)
   │
   │ 3. Escucha socket localabstract:autopilot
   │    Recibe JSON-RPC, ejecuta UiAutomation queries,
   │    responde JSON-RPC
   ▼
UiAutomation API del device (dentro del mismo proceso de la app target)
```

**Simetría pretendida con ARD-002:** lo mismo ocurrirá en iOS con `libAutoPilotObserver.a` linkeada al binario de la app.

---

## Dependencies externas

**Ninguna a runtime.** Swift puro, `xcrun`, `adb`. Sin npm, sin pip, sin Ruby.

**Build dependencies:**
- Swift 5.9+ / Xcode 15+ (Simulator 26 Compatible)
- Android SDK + adb (solo para `auto-android`)
- Rust toolchain (solo para compilar el editor Tauri)

**Runtime dependencies del editor:**
- Tauri 2 runtime (compilado dentro del bundle)
- WebView del sistema
- Monaco editor (bundled)

---

## Métricas de salud (snapshot)

| Métrica | Valor |
|---------|-------|
| Tests unitarios | 121 / 121 verdes |
| Build warnings | 0 |
| LOC total `cli/Sources/` | ~8,000 |
| Archivo más grande | `+SimCtlEngine.swift` (677 LOC) |
| iOS tap warm (AX fast) | ~200ms |
| iOS tap warm (XCUI fallback) | ~430ms |
| Android tap warm | ~50ms (agent) |
| `waitFor` iOS mediana | ~153ms (vs 596ms pre-PR #109) |
| Cold boot runner XCTest | 10-45s primera vez, ~400ms siguientes |

---

## Puntos de extensión conocidos

Si querés agregar funcionalidad nueva, estos son los hooks:

### Nuevo comando (ej. `auto foo bar`)
1. Agregá el case en `CommandDispatcher.executeSharedCommand()`
2. Si necesita nuevo `ActionKind`, agregalo a `Backend.swift`
3. Implementalo en al menos un backend (sino el router lanza `noBackendForAction`)

### Nuevo backend (ej. MaestroBackend para iOS)
1. Creá `MaestroBackend.swift` como factory con capabilities declaradas
2. Registralo en `iOSDeviceResolver.init()` en el orden correcto (fast first, fallback last)
3. Si el backend es stateful, usá `LegacyBridgeAdapter` para envolver un bridge existente

### Nueva plataforma (ej. macOS desktop apps automation)
1. Nueva carpeta `cli/Sources/AutoLibMacOS/`
2. Implementá bridges + backends siguiendo patrón iOS/Android
3. Nuevo CLI `cli/Sources/CLIMacOS/main.swift` que construye `MacOSDeviceResolver`
4. Agregalo a `Package.swift`

### Nuevo comando iOS-específico no genérico
Si el comando no tiene sentido como `Action` (ej. "enable keyboard hardware" que es una quirk de iOS Simulator), se queda en `SimulatorBridge.swift` como método público y el CLI lo llama directo (no via router).

---

## Invariantes arquitecturales

Al trabajar en este código, respetá estos invariantes (romperlos es bug):

1. **CLIs no tienen lógica de ejecución.** Solo parsing + dispatch. Si añadís lógica en `main.swift`, probablemente va en un helper (`iOSXxxEnhancement.swift`) o en el dispatcher.

2. **`DeviceBridge` legacy no se extiende.** Es deprecated. Cualquier método nuevo va al `Backend` protocol como nuevo `ActionKind`.

3. **Backends no tienen estado cross-command.** Si necesitás memoria (ej. elementIndex cache), va en el bridge subyacente, no en el backend.

4. **Scripts `.auto` nunca referencian plataforma.** Si un script solo funciona en iOS, es porque usa comandos iOS-specific — no porque tenga un `if ios {}`.

5. **No emojis en código** (convención del proyecto, marcada en CLAUDE.md).

6. **Comentarios en español, commits/código en inglés.**

---

## Riesgos conocidos

Ver [POSTMORTEMS.md](POSTMORTEMS.md) para contexto completo. Los puntos "vivos":

- **XCUI cold boot 10-45s** — primer tap en una sesión nueva puede timeout si el dev no conoce el workflow. Mitigado con `auto setup` warmup.
- **AX stale tras clicks rápidos** (#52) — resuelto en PR #108, pero el patrón puede reaparecer en el recorder si se agregan nuevos tipos de eventos.
- **iOS device no funciona** — bloqueado por arquitectura. Fix planeado en [ARD-002](rfc/ARD-002-ios-in-process-observer.md).
- **SwiftUI sin contentDescription** — mitigado con escalation router → XCUI, pero cada tap en una app SwiftUI-pura paga ~430ms de roundtrip.

---

## Ver también

- [HISTORY.md](HISTORY.md) — evolución cronológica
- [POSTMORTEMS.md](POSTMORTEMS.md) — fracasos y lecciones
- [ROADMAP.md](ROADMAP.md) — qué sigue
- [rfc/ARD-001-backend-pattern.md](rfc/ARD-001-backend-pattern.md) — decisión arquitectural base
- [rfc/ARD-002-ios-in-process-observer.md](rfc/ARD-002-ios-in-process-observer.md) — próximo proyecto grande
- [ios/XCUI-BRIDGE.md](ios/XCUI-BRIDGE.md) — detalles del runner XCTest
- [libro/](libro/) — 15 capítulos de fondo conceptual
