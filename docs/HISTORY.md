# AutoPilot — Historia del proyecto

Cronología honesta de la evolución, con logros y fracasos marcados. Cada hito tiene referencia al PR/issue original para que puedas rastrear el razonamiento y ver el diff.

Este documento es el **timeline técnico** — no marketing. Si algo no funcionó, está acá.

---

## Resumen ejecutivo

AutoPilot nació para resolver un problema puntual: **automatizar una app iOS con cámara mock sin tocar el Xcode project ni recompilar**. Esa meta se logró y se extendió a cross-platform iOS + Android, al editor Tauri, al recorder semántico, al benchmark competitivo, y finalmente a una arquitectura de backends con capability discovery.

El proyecto tiene dos mitades claras:

1. **"Hacer que funcione"** (primeras fases): lib estática para cámara, bridge iOS, bridge Android, editor, recorder, benchmark. Mayormente escrito como iteración directa sobre el problema.

2. **"Hacer que escale"** (ARD-001 en adelante): el bridge monolítico y los CLIs duplicados se volvieron imposibles de mantener. Reemplazo arquitectural completo vía Command + Capability Discovery.

Ahora arranca una tercera fase ("hacer que llegue a device físico") con ARD-002, aún sin implementar.

---

## Línea de tiempo

### 📐 Fase 0 — Fundamentos (pre-marzo 2026)

**Logros:**
- CLI `auto` en Swift puro (sin dependencias) — filosofía del proyecto
- Mock de cámara iOS via lib estática con method swizzling
- `BuildInterceptor` intercepta `xcodebuild` sin tocar el Xcode project
- Scripts `.auto` como lenguaje de automatización

**Limitaciones asumidas:**
- Solo iOS Simulator
- Solo UIKit legible vía AX macOS (SwiftUI quedaba afuera)

---

### 🤖 Fase 1 — Paridad Android (marzo 2026)

**Logro:** `auto-android` con dos backends:
- `AgentBridge` via socket TCP a una instrumentación UiAutomation dentro del proceso (fast path)
- `AdbLegacyBridge` via `adb shell uiautomator dump` (fallback lento)

**Resultado:** mismo script `.auto` corre en iOS y Android.

**Fracasos encontrados:**
- ⚠️ Primer intento con solo `adb shell` era **demasiado lento** (~2s por tree dump). Por eso se escribió el agente APK nativo.
- ⚠️ Android Compose buttons sin `contentDescription` no son tappables por label — resuelto después con `AndroidComposeResolver` en PR #106.

---

### 📊 Fase 2 — Benchmark suite (abril 2026, PR #33)

**Logro:** suite de benchmarks comparativa vs Maestro vs WDA:

| Framework | Tiempo (n=10) |
|-----------|--------------|
| **AutoPilot** | **10.2s** ⭐ |
| WDA | 11.7s |
| Maestro | 26.1s |

Los números de AutoPilot son reales sobre Explorea con login + biometric match + home.

**Aprendizajes:**
- Maestro es ~2.5× más lento en flujos con biometry
- WDA es competitivo pero requiere setup pesado
- AutoPilot era competitivo sin XCUI — pero ciego a SwiftUI

---

### 🎙️ Fase 3 — Recorder semántico (abril 2026, PR #45)

**Objetivo:** grabar interacciones → emitir script `.auto` reproducible.

**Logros:**
- Captura de `mouseDown`/`mouseUp` via `CGEventTap` (listenOnly)
- Resolución semántica: el recorder emite `tap "Login"` en lugar de `tapAtCoordinate(x, y)`
- Soporte de `role[N]` y `within` para ambigüedad

**Fracaso registrado**  ⚠️ (ver [recorder_experiment_findings.md](../../.claude/projects/-Users-fsaldivar-Documents-Automation-AutoPilot/memory/recorder_experiment_findings.md)):

> Bug P0: recorder emite `waitFor "<value>"` por contenidos de fields → script grabado nunca se reproduce (replay falla 50%).

3 intentos, 90 vs 30 líneas grabadas, factor escala MCP↔AX 1.26. El recorder capturaba el **valor actual** de un text field como si fuera un label estático → en el replay el valor era distinto. **Lección:** no usar AX `value` como selector, solo label/title/identifier.

**Fix:** commit [`55c1acf`](https://github.com/fsaldivar-dev/AutoPilot/commit/55c1acf) — skip AXTextField value as selector fallback.

---

### 🔧 Fase 4 — XCUI Bridge para SwiftUI (abril 16 2026)

**Problema:** AX macOS ve los botones de SwiftUI `ToolbarItem(.navigationBar*)` como elementos aplanados sin label. Los scripts `tap "Back"` fallaban silenciosamente.

**Logro:** `XCUIBridge` — cliente TCP directo al runner XCTest dentro del simulador (puerto 22087). Usa `XCUIApplication.navigationBars` que SÍ ve SwiftUI.

**Arquitectura (previa a ARD-001):**
```
HybridBridge (escalation manual)
├── SimulatorBridge (fast, AX macOS)
└── XCUIBridge (deep, XCTest runner)
```

**Logros paralelos:**
- `auto list buttons` — typed listing en ~1s vs `tree deep` en 13s
- Runner inmortal con `--timeout 0`
- Tap warm bajado de 1500ms → 430ms (paridad Maestro)

**Gotchas documentados:**
- ⚠️ **Xcode 26 clona el simulator por defecto** para tests paralelos. Al terminar el test, mata el clon y el simulator principal se cae con él. Fix: `-parallel-testing-enabled NO`.
- ⚠️ XCUI requiere main thread — no se puede llamar desde threads arbitrarios.

Ver [docs/ios/XCUI-BRIDGE.md](ios/XCUI-BRIDGE.md).

---

### 💬 Fase 5 — Interactive REPL + keychain reset (abril 8 2026)

**Objetivo:** el editor Tauri usa `auto interactive` como long-running subprocess. Sin REPL, cada step del script pagaba ~100ms de cold start + perdía estado del stabilizer.

**Logros:**
- Modo `auto interactive` con protocol NDJSON over stdin/stdout
- Warm bridge + warm stabilizer entre steps → 0 cold start
- `keychain reset` cross-platform (iOS: `simctl keychain`, Android: no-op documentado)

**Bench vs Maestro en flujo login Uala:** ~6s AP vs ~8s Maestro (Maestro perdía en keychain handling).

---

### 🚧 Fase 6 — Observer waitFor hybrid (abril 2026) — **REVERTED**

**Objetivo:** convertir `waitFor` de poll 500ms a event-driven via `AXObserver`. Esperado: latencia <100ms en lugar de 500ms.

**Resultado:** ❌ **50% pass rate** (3/6 runs vs 100% con poll antiguo). Feature revertida.

**Root cause** (ver [feedback_observer_hybrid.md](../../.claude/projects/-Users-fsaldivar-Documents-Automation-AutoPilot/memory/feedback_observer_hybrid.md)):

El simulator emite eventos AX a **20-30 eventos/segundo** durante init de app. Cada evento dispara un `search()` tree dump (~30ms). Con ese rate, gastábamos ~100% CPU dumpeando y nos perdíamos transiciones breves (dialogs <200ms).

El poll 500ms "funcionaba por accidente" — su lentitud daba breathing room al simulator.

**Lección:** event-driven sin **coalescing agresivo** + **query barata** es peor que poll bien configurado. Documentado como bloqueo en issue [#79](https://github.com/fsaldivar-dev/AutoPilot/issues/79).

**Resolución (PR #109 después):** `existsFast()` shallow (~5ms vs 30ms) + poll 100ms = misma CPU, 3.9× más rápido, sin oversampling.

---

### 🏗️ Fase 7 — ARD-001 Backend Pattern (abril 2026, PR #106)

**Problema detectado:**
- `DeviceBridge` protocol con 53 métodos — implementaciones con `notImplemented()` en 36/53
- `HybridBridge` escalaba solo 5/53 métodos
- `CLI/main.swift` (873 LOC) reimplementaba ~40 comandos ya existentes en `CommandDispatcher`
- `SimulatorBridge.swift` monolítico (1964 LOC)
- Agregar un nuevo motor (Maestro, WDA, etc.) requería tocar múltiples wrappers

**Decisión arquitectural:** Command Pattern + Capability Discovery.

**Paradigma:**
```swift
enum Action { case tap(Selector), type(String), screenshot(String), ... }
protocol Backend {
    var capabilities: Set<ActionKind> { get }
    func execute(_ action: Action) async throws -> ActionResult
}
actor ActionRouter {  // escala automáticamente entre backends
    func execute(_ action: Action) async throws -> ActionResult { ... }
}
```

**Logros:**
- `ActionRouter` + `CapabilityRegistry` + `Backend` protocol (AutoCore)
- `AXBackend` / `XCUIBackend` / `SimCtlBackend` / `MediaBackend` (iOS)
- `AgentBackend` / `AdbBackend` (Android)
- `iOSDeviceResolver` / `AndroidDeviceResolver` — bootstrap automático
- `CLI/main.swift` 873 → **483 LOC** (−45%)
- `CLIAndroid/main.swift` 632 → **255 LOC** (−60%)
- Tests 96 → **110** (+ActionRouter + BackendRegistration suites)
- Resuelve issues #52, #59, #96-#105

**Mantuvo:**
- API de `DeviceBridge` (legacy) via `LegacyBridgeAdapter` — ningún script `.auto` se rompió
- `HybridBridge` como modo explícito vía `AUTO_BRIDGE=hybrid`

Ver [docs/rfc/ARD-001-backend-pattern.md](rfc/ARD-001-backend-pattern.md).

---

### 🐛 Fase 8 — Recorder fixes (PR #108)

**Resolvió:**
- **#52** stale AX tree en clicks rápidos — `captureRootAvoidingStaleTree(for:)` con polling de fingerprint
- **#50** trackpad scroll no detectado — fallback a `scrollWheelEventPointDeltaAxis1` para smooth scroll

**Detalle técnico:** trackpad smooth scroll emite `scrollWheelEventDeltaAxis1 = 0` y la delta real (en píxeles) va en `scrollWheelEventPointDeltaAxis1`. Mouse wheel tradicional usa el primero.

---

### 🎯 Fase 9 — waitFor 3.9× faster + editor refresh (PR #109)

**Logros:**
- `DeviceBridge.existsFast(label:)` nuevo método — shallow query sin full tree dump (~5-10ms vs ~30-50ms)
- `waitFor` / `waitUntilGone` refactor — poll 100ms + `existsFast` → 3.9× más rápido (596ms → 153ms en smoke test)
- `editor/src-tauri/tauri.conf.json` invoca `refresh-binaries.sh` en `beforeDevCommand` — `cargo clean` ya no deja binarios stale

**Resolvió:**
- #79 (event-driven waitFor) — cerrado con approach híbrido (no event-driven puro, pero logró el objetivo de performance)
- #81 (editor binary refresh)

---

### 🧹 Fase 10 — SimulatorBridge split (PR #110)

**Objetivo:** deuda técnica de ARD-001 — 4 backends wrapper aún tenían todo el código real en `SimulatorBridge.swift` (1964 LOC).

**Estrategia:** extension-based split. Cada engine es una extension del mismo tipo `SimulatorBridge` en un archivo separado.

**Resultado:**

| Archivo | LOC | Rol |
|---------|-----|-----|
| `SimulatorBridge.swift` | **677** (de 1964, **−65%**) | gestures + input + state |
| `+AXEngine.swift` | 521 | AX queries + element search |
| `+SimCtlEngine.swift` | 677 | simctl + biometry + files |
| `+MediaEngine.swift` | 200 | screenshot + recording + camera |

**Invariantes preservados:** API pública sin cambios, `LegacyBridgeAdapter` funciona igual, tests 121/121 verdes.

---

### 🔮 Fase 11 — ARD-002 iOS Observer (abril 2026, plan)

**Aún sin implementar.** Ver [docs/rfc/ARD-002-ios-in-process-observer.md](rfc/ARD-002-ios-in-process-observer.md) y [epic #111](https://github.com/fsaldivar-dev/AutoPilot/issues/111).

**Objetivo:** habilitar iPhone físico como target + eliminar XCUI fallback.

**Approach:** lib estática linkeada en build-time al binario firmado iOS. Corre dentro del proceso, abre TCP socket, responde RPC al CLI. Arquitectura simétrica al agente Android.

**Estimado:** ~100-120h distribuido en 5 fases deployables.

---

## Logros acumulados

- ✅ iOS Simulator E2E con camera mock — sin tocar Xcode project
- ✅ Android emulator + device USB con agent nativo
- ✅ Editor Tauri con REPL interactive + Monaco editor
- ✅ Recorder semántico (iOS + Android)
- ✅ Benchmark competitivo vs Maestro/WDA
- ✅ Arquitectura Command + Capability Discovery escalable
- ✅ 121 tests unitarios + CI verde
- ✅ Documentación técnica (libro 15 capítulos + RFCs)

## Fracasos aprendidos

- ❌ Event-driven `waitFor` sin debouncing → 50% pass rate, revertido
- ❌ AX `value` como selector en recorder → scripts no reproducibles
- ❌ Xcode 26 clona simulator → tests parallelos matan el sim padre
- ❌ `DYLD_INSERT_LIBRARIES` no funciona en iOS device (por eso ARD-002)
- ❌ AX macOS ciego a SwiftUI NavBar (mitigado con XCUI, resuelve def. en ARD-002)

Cada uno de estos fracasos está documentado en [docs/POSTMORTEMS.md](POSTMORTEMS.md).

---

## Ver también

- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — estado técnico actual
- [docs/ROADMAP.md](ROADMAP.md) — qué sigue
- [docs/POSTMORTEMS.md](POSTMORTEMS.md) — casos de estudio de fracasos
- [docs/libro/](libro/) — el libro técnico (15 capítulos + apéndices)
- [docs/rfc/](rfc/) — RFCs/ARDs
