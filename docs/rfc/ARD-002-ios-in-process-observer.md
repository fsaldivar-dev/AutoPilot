# ARD-002 — In-Process iOS Observer

**Estado:** Propuesto (pendiente de aprobación)
**Fecha:** 2026-04-19
**Autor:** fsaldivar-dev
**Predecesor:** [ARD-001 Backend Pattern](ARD-001-backend-pattern.md) (mergeado en PR #106)

---

## TL;DR

Reemplazar AX macOS + XCUI runner por una **librería Swift/ObjC inyectada en build-time** dentro del proceso iOS. La app corre con el observer integrado, expone un socket IPC, y el CLI consume UI tree + eventos desde adentro del proceso.

Habilita **iOS device físico como target de primera clase** (hoy bloqueado por arquitectura AX-macOS) y mejora latencia ~10× en simulator. Arquitectura simétrica con el agente Android existente.

---

## Contexto

### El problema actual

AutoPilot iOS opera **desde afuera** del proceso app:

```
auto (macOS process)
   ↓ AXUIElementCreateApplication()
Simulator.app (AX macOS expone solo lo que UIKit publica)
   ↓ opaco
iOS app process
```

Esto tiene tres limitaciones duras:

1. **AX macOS no ve iPhone físico.** `AXUIElementCreateApplication()` lista apps macOS — Simulator sí aparece, un device USB no. Por eso hoy no podemos correr tests en iPhone físico.
2. **SwiftUI aplanado.** AX macOS recibe lo que UIKit expone; SwiftUI NavigationBar buttons, tabs y muchos elementos de Compose-style no se reportan o se reportan sin label. Hoy compensamos con `XCUIBackend` que sí los ve, al costo de ~1400ms por tap.
3. **Latencia query alta.** Cada `tree()` cuesta ~30-50ms (IPC de AX + serialize). Con el in-process observer, el mismo query es ~2-5ms porque vive en el mismo process space.

### Lo que Android ya tiene

El `AgentBridge` Android no sufre esto porque el **agent APK corre dentro del device** (UiAutomation, same process como la app):

```
auto-android → adb forward tcp:9008 localabstract:autopilot
             → agent.apk (UiAutomation dentro del device, emulator o físico)
             → serializa el view tree desde adentro, responde RPC
```

iOS merece la misma arquitectura simétrica.

### Por qué este approach (no `DYLD_INSERT_LIBRARIES`)

iOS device bloquea `DYLD_INSERT_LIBRARIES` a nivel kernel por security policy. Solo `xcrun simctl` lo habilita en simulator via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`.

**Solución:** linkear la lib **en build-time** (`-force_load`). La lib queda compilada dentro del Mach-O firmado con dev certificate — iOS la trata como código propio de la app, sin distinguirla del código nativo. Cero bloqueo.

Esto implica: para instrumentar una app, necesitamos **acceso al Xcode project** (o el `.ipa` + proceso de re-signing). Para apps del team que automatiza (caso normal), esto está disponible.

---

## Decisión

Crear una librería estática `libAutoPilotObserver.a` que:

1. Se linkea en el binario de la app con `-force_load` durante build
2. Al cargarse (`__attribute__((constructor))`) instala swizzlings de UIKit + abre un socket IPC
3. Expone una API RPC (`tree`, `tap`, `exists`, `waitForEvent`, etc.) sobre ese socket
4. Convive con AX macOS + XCUI como **fallback** — el `iOSDeviceResolver` detecta cuál está disponible

El CLI consume esto vía un nuevo backend `iOSAgentBackend` (factory ARD-001) espejo del `AgentBackend` Android.

---

## Arquitectura

### Diagrama

```
ANTES (arquitectura actual post-ARD-001):

  auto (CLI macOS)
      ↓
  ActionRouter
      ├── AXBackend (AX macOS, ciego a SwiftUI)
      ├── XCUIBackend (XCTest runner, lento, simulator-only)
      ├── SimCtlBackend (lifecycle)
      └── MediaBackend


DESPUÉS (con ARD-002):

  auto (CLI macOS)
      ↓
  ActionRouter
      ├── iOSAgentBackend ← NUEVO — primario si observer instalado
      │       ↓ TCP socket (simulator: local / device: devicectl forward-port)
      │   libAutoPilotObserver.a (dentro del proceso iOS)
      │       ├── UIApplication.sendEvent swizzle (captura taps)
      │       ├── UIView hierarchy introspection (layout real)
      │       ├── SwiftUI _ViewHost reflection
      │       └── UIGestureRecognizer hooks
      │
      ├── AXBackend (fallback si observer no disponible)
      ├── XCUIBackend (fallback segundo nivel)
      ├── SimCtlBackend / DeviceCtlBackend ← NUEVO (devicectl)
      └── MediaBackend
```

### Componentes nuevos

#### 1. `libAutoPilotObserver.a` (ObjC/Swift)

**Ubicación:** `libs/AutoPilotObserver/` (nuevo directorio)

Implementa desde **dentro del proceso iOS**:

```
AutoPilotObserver/
├── Observer.swift           Entry point, __attribute__((constructor))
├── Swizzle.m                Swizzle UIApplication.sendEvent, UIGestureRecognizer
├── ViewSerializer.swift     UIView tree → JSON recursivo
├── SwiftUIReflector.swift   _ViewHost internals + ViewModifier extraction
├── IPCServer.swift          TCP socket (127.0.0.1:7002 en simulator,
│                            mismo puerto via devicectl forward en device)
├── RPCHandler.swift         Dispatch de métodos (tree, tap, exists, etc.)
├── EventBus.swift           Captura taps + analytics events (future #79-like)
└── Module.modulemap         Para interop C/ObjC/Swift
```

**Responsabilidades:**
- Swizzle al load (método `+load` de una ObjC class dummy)
- Iniciar `IPCServer` en un background thread
- Escuchar comandos JSON-line del CLI
- Responder con UI tree / resultados de actions

**Protocol IPC (compatible con Android AgentBridge):**

```json
// Request
{"id":"42","method":"tree","params":{}}

// Response
{"id":"42","result":[{"role":"Button","label":"Login","frame":{"x":20,"y":80,"w":120,"h":40}, ...}]}
```

El protocolo es intencionalmente idéntico al que usa `AgentBridge` Android — eso permite al CLI tratar ambos backends simétricamente (y validar parity cross-platform con el mismo test suite).

#### 2. `iOSAgentBridge.swift` (cliente en CLI)

**Ubicación:** `cli/Sources/AutoLibiOS/iOSAgentBridge.swift` (nuevo)

Espejo casi literal de `cli/Sources/AutoCore/AgentBridge.swift`:

```swift
public final class iOSAgentBridge: DeviceBridge {
    private let port: Int
    private var socket: Int32 = -1

    public init(port: Int = 7002) {
        self.port = port
    }

    public func tap(target: String) throws {
        let _ = try sendCommand("tap", params: ["target": target])
    }

    public func tree() throws -> [[String: Any]] {
        let result = try sendCommand("tree")
        return result as? [[String: Any]] ?? []
    }

    // ... resto simétrico a AgentBridge Android
}
```

Reutilizamos el patrón de auto-recovery del `AgentBridge` Android (se reconecta si el socket muere, reintenta con backoff).

#### 3. `iOSAgentBackend` (factory ARD-001)

**Ubicación:** `cli/Sources/AutoLibiOS/iOSAgentBackend.swift` (nuevo)

```swift
public enum iOSAgentBackend {
    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe, .tapAtCoordinate,
        .tree, .search, .elementAt, .existsFast,
        .typeText, .pressKey, .hideKeyboard,
        .viewport,
        // NO incluye: install, launch, screenshot (esos van por DeviceCtl/SimCtl)
    ]

    public static func make(bridge: iOSAgentBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(bridge)
        )
    }
}
```

#### 4. `DeviceCtlEngine.swift` (lifecycle iOS device físico)

**Ubicación:** `cli/Sources/AutoLibiOS/SimulatorBridge+DeviceCtlEngine.swift` (extension nueva, igual patrón que +SimCtlEngine/+AXEngine/+MediaEngine del PR #110)

Wrappers sobre `xcrun devicectl`:

```swift
extension SimulatorBridge {
    /// Install .ipa en device físico via devicectl (Xcode 15+).
    public func installAppOnDevice(path: String, deviceUDID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "install", "app",
                             "--device", deviceUDID, path]
        // ... run + error handling
    }

    public func launchAppOnDevice(...) { ... }
    public func terminateAppOnDevice(...) { ... }
    public func forwardPortOnDevice(localPort: Int, devicePort: Int, udid: String) throws {
        // xcrun devicectl device forward-port ...
        // Corre en background process, retorna handle
    }
}
```

Nuevo `DeviceCtlBackend` factory análogo a `SimCtlBackend` pero para device físico.

#### 5. `iOSDeviceResolver` actualizado

**Cambios en:** `cli/Sources/AutoLibiOS/iOSDeviceResolver.swift` (existe, se extiende)

Pseudocódigo:

```swift
public init() {
    let deviceType = detectDeviceType()  // simulator | physical | none

    switch deviceType {
    case .simulator(let udid):
        // Como hoy: AX + XCUI + SimCtl + Media
        // PLUS: intentar conectar a iOSAgentBridge en TCP 7002;
        //       si conecta, registrarlo con prioridad sobre AXBackend
        registerSimulatorBackends(udid: udid)

    case .physical(let udid):
        // Nuevo path:
        //   1. devicectl forward-port 7002 (si no está activo)
        //   2. iOSAgentBridge conecta
        //   3. DeviceCtlBackend para lifecycle
        //   4. NO registra AXBackend ni XCUIBackend (no funcionan en físico)
        try setupPhysicalDevice(udid: udid)

    case .none:
        throw ResolverError.noDeviceAvailable
    }
}
```

---

## Fases de implementación

Total estimado: **~100-120h**. Cuatro fases deployables:

### Fase 1 — Observer lib + IPC (simulator only) — ~35h

**Entregable:** `libAutoPilotObserver.a` funciona en simulator. `iOSAgentBridge` conecta al socket, pide `tree` y `tap`, funciona end-to-end.

Archivos nuevos:
- `libs/AutoPilotObserver/Observer.swift`
- `libs/AutoPilotObserver/Swizzle.m`
- `libs/AutoPilotObserver/ViewSerializer.swift`
- `libs/AutoPilotObserver/IPCServer.swift`
- `libs/AutoPilotObserver/RPCHandler.swift`
- `libs/AutoPilotObserver/Makefile` (build script cross-arch)
- `cli/Sources/AutoLibiOS/iOSAgentBridge.swift`
- `cli/Sources/AutoLibiOS/iOSAgentBackend.swift`
- `cli/Tests/iOSAgentBridgeTests.swift`

Verificación:
- `xcodebuild` compila CameraTestApp con `-force_load libAutoPilotObserver.a`
- App lanza, observer abre socket 7002
- `auto tree` via `iOSAgentBackend` retorna UIView tree completo
- `auto tap "Login"` via el observer, latencia medida <10ms

### Fase 2 — SwiftUI introspection — ~20h

**Entregable:** El observer ve SwiftUI completo (NavigationBar, TabView, sheets modals).

Archivos:
- `libs/AutoPilotObserver/SwiftUIReflector.swift` — accede a `_ViewHost` internals via `Mirror` y private ObjC APIs
- Tests end-to-end contra app Explorea: `auto tap "Desbloquear con biometría"` sin escalation a XCUI

### Fase 3 — Device físico (devicectl + forwarding) — ~30h

**Entregable:** `auto run script.auto` funciona en iPhone conectado por USB.

Archivos nuevos:
- `cli/Sources/AutoLibiOS/SimulatorBridge+DeviceCtlEngine.swift`
- `cli/Sources/AutoLibiOS/DeviceCtlBackend.swift` — factory ARD-001
- `cli/Sources/AutoLibiOS/iOSDeviceResolver.swift` — logic de detección simulator vs physical
- Documentación: `docs/ios/PHYSICAL-DEVICE.md` — setup de dev cert, USB debugging, troubleshooting

Verificación:
- `auto list` muestra device físico
- `auto install --device App.ipa` funciona
- `auto launch` + `auto tap` + `auto screenshot` funcionan en device real
- Smoke suite ARD-001 pasa en device físico

### Fase 4 — Build integration + hot reload — ~20h

**Entregable:** `auto build --device` automatiza el linking de la observer lib. Cambios en la lib no requieren rebuild completo de la app.

Archivos:
- `cli/Sources/AutoLibiOS/BuildInterceptor.swift` — extender para manejar `-force_load libAutoPilotObserver.a`
- `cli/Sources/CLI/main.swift` — flag `--device` en `auto build`
- Dev cert auto-detect (reutilizar existing in Xcode account)

### Fase 5 — Fallback + gradual rollout — ~15h

**Entregable:** Si la observer lib no está en la app, el sistema cae a AX/XCUI actual. Permite migración gradual — apps sin observer siguen funcionando.

---

## Invariantes de compatibilidad

**No negociables** (cualquier fase que los rompa no se mergea):

1. **Backwards compatibility:** `auto run scripts/examples/smoke-ard001.auto` en simulator sin observer → sigue funcionando vía `AXBackend` + `XCUIBackend`.
2. **Mismo protocolo IPC que Android:** el JSON que responde el observer iOS es 100% intercambiable con el formato que emite el agent Android. Facilita testing cross-platform del CLI.
3. **Sin breaking changes a la API pública** de `SimulatorBridge` ni del `DeviceBridge` protocol. Todos los cambios son aditivos.
4. **`.autopilot` config sin cambios.**
5. **Los tests del ARD-001 (110+) pasan sin modificación.**

---

## Riesgos y mitigaciones

| Riesgo | Probabilidad | Mitigación |
|--------|--------------|------------|
| Apple rompe los swizzle en una versión futura de iOS | Media | Test matrix en iOS 17, 18, 26. Mantener fallback XCUI vivo. |
| Observer lib corrompe el proceso de la app bajo test | Baja | Extensive testing, `__attribute__((constructor))` es pattern estándar (Sentry, Firebase, etc. lo usan). Feature flag que desactiva observer sin rebuild. |
| `xcrun devicectl` port forwarding inestable | Baja | Fallback a usbmux vía ios-deploy. Ambos path implementados desde Fase 3. |
| SwiftUI internals cambian entre versiones de Xcode | Media | Usar primero APIs públicas (`Mirror`, accessibility API). Solo tocar privados como último recurso. |
| Dev cert setup fricciona adopción | Baja (audiencia técnica) | Documentación clara. Personal Team funciona para testing. |
| Performance del serializer recursivo en árboles grandes (>500 views) | Media | Benchmark en fase 1. Implementar shallow serialization (max depth configurable) como tenemos en AX. |

---

## Arquitectura de decisión: ¿por qué no X?

**¿Por qué no Appium?** Appium usa XCUITest como backend, mismo bottleneck de velocidad. Además depende de un server Node externo — fricciona el "Swift puro, sin dependencias externas" del proyecto.

**¿Por qué no Maestro?** Maestro tiene un approach similar (inyección via XCUITest) pero orquesta scripts desde YAML en un process externo. AutoPilot ya tiene su modelo (scripts `.auto`, protocolo ARD-001) — no queremos embedder Maestro dentro.

**¿Por qué no Frida?** Frida requiere re-signing de la app y carga ~100MB de runtime. Para in-process UI introspection simple, es overkill. Nos guardamos Frida como opción futura si necesitamos hot-swap runtime (hoy no es requisito).

**¿Por qué no solo mejorar XCUI?** XCUI runner tiene un ceiling duro de ~400ms por tap warm. In-process observer baja eso a ~5-10ms — diferencia de un orden de magnitud. Además XCUI sigue sin funcionar en device sin jailbreak del deployment pipeline.

---

## Archivos críticos (referencia)

Para la sesión futura que implemente esto, los archivos relevantes del codebase actual:

| Archivo | Por qué es relevante |
|---------|----------------------|
| `cli/Sources/AutoCore/AgentBridge.swift` | **Espejo a seguir** — la estructura del cliente IPC Android es el modelo a replicar para iOS |
| `cli/Sources/AutoLibiOS/SimulatorBridge.swift` | Nuevo core post-PR #110 — veremos dónde engancha el `iOSAgentBridge` |
| `cli/Sources/AutoLibiOS/iOSDeviceResolver.swift` | Se extiende para detectar simulator vs physical |
| `cli/Sources/AutoLibiOS/BuildInterceptor.swift` | Ya linkea libraries en build — se extiende para observer lib |
| `cli/Sources/AutoCore/Backend.swift` + `ActionRouter.swift` | Contrato ARD-001 al que el nuevo backend se integra |
| `agent/android/` (proyecto separado) | Reference implementation del agent dentro del proceso — misma idea trasladada a iOS |
| `docs/rfc/ARD-001-backend-pattern.md` | Paradigma base que este ARD extiende |

---

## Plan de verificación

Para cerrar cada fase:

```bash
# Build clean sin warnings
cd cli && swift build

# Tests unitarios sin regresión
swift test   # debe pasar 110+ tests existentes + nuevos

# Simulator smoke (Fase 1-2)
auto run scripts/examples/smoke-ard001.auto
# Expected: 7/7 pasos con latencia menor a baseline (waitFor ~50ms vs 150ms actual)

# Device físico smoke (Fase 3+)
auto list --device
auto run scripts/examples/smoke-ard001.auto
# Expected: funciona contra iPhone USB, labels visibles en SwiftUI

# Parity con Android
# Mismo script .auto corre en: iOS simulator, iOS device, Android emulator, Android device
```

---

## Próximos pasos

1. **Aprobación del ARD** (este documento) — revisión y ajustes antes de empezar código.
2. **Crear issues en GitHub** — uno epic + sub-issues por fase (ver sección "Issues propuestos" abajo).
3. **Prototipo Fase 1** — aislado, solo para validar que el observer se carga, swizzle funciona, socket abre.
4. **RFC de protocolo IPC** — documento aparte con el contrato exacto del JSON-RPC (puede ser apéndice de este ARD).

---

## Issues propuestos (para crear al aprobar)

```
Epic #NEW: [arch] ARD-002 — In-process iOS Observer for device + simulator

Sub-issues:
  - [arch] Phase 1 — libAutoPilotObserver.a + IPC server in simulator
  - [arch] Phase 2 — SwiftUI introspection via Mirror + private APIs
  - [arch] Phase 3 — Physical iOS device support via devicectl + forward-port
  - [arch] Phase 4 — auto build --device + dev cert auto-detect
  - [arch] Phase 5 — Fallback to AX/XCUI when observer unavailable
  - [docs] RFC IPC protocol (JSON-RPC contract)
  - [docs] docs/ios/PHYSICAL-DEVICE.md — setup guide para devs
```

---

## Referencias

- ARD-001: [docs/rfc/ARD-001-backend-pattern.md](ARD-001-backend-pattern.md)
- Agent Android architecture: `agent/android/` directory
- Apple `xcrun devicectl` docs: https://developer.apple.com/documentation/xcode/devicectl
- Method swizzling in ObjC: Apple's runtime.h + `class_replaceMethod`
- Related: PR #106 (ARD-001 merge), PR #110 (SimulatorBridge split — la base sobre la que se extiende)
