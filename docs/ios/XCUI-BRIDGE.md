# XCUIBridge — Motor híbrido de control iOS

AutoPilot tiene **dos motores** de control iOS que trabajan en conjunto bajo un `HybridBridge`. El primero (`SimulatorBridge`) usa AX de macOS y es ultra rápido. El segundo (`XCUIBridge`) usa un runner XCTest dentro del simulador y ve elementos que el AX de macOS no puede resolver (NavigationBar SwiftUI, elementos internos de apps, etc.).

Este documento explica cómo se compone la arquitectura, cuándo escala de fast a deep, y cómo correr el sistema manualmente para debug.

---

## Por qué dos motores

`SimulatorBridge` llega a AX desde fuera del proceso de la app bajo test — desde `Simulator.app` en macOS. Ese AX se construye a partir de lo que UIKit exporta, y **SwiftUI no siempre expone su NavigationBar** por ahí. Resultado: botones de `ToolbarItem(.navigationBar*)` no son tapeables por label, y scripts acaban usando coordenadas frágiles.

`XCUIBridge` habla con un runner XCTest que corre **dentro del runtime del simulador**. Desde ahí, `XCUIApplication.navigationBars` sí ve la NavBar como elemento de primera clase con identifier y children. El precio es un socket roundtrip extra por cada comando.

El `HybridBridge` las usa en escalera: fast primero, deep solo si el fast tira `elementNotFound`. 80–90% de los taps se resuelven en el fast-path sin sacrificar perf.

---

## Diagrama

```
┌─────────────────────┐
│   auto (CLI)        │
│   main.swift:       │
│   makeBridge() →    │
└──────────┬──────────┘
           │
           ▼
┌──────────────────────────────────────────────┐
│   HybridBridge                               │
│   política: tap/search/scroll escalan        │
│   launch/simctl/biometric → fast siempre     │
└─────┬─────────────────────────┬──────────────┘
      │ fast                    │ deep (on elementNotFound)
      ▼                         ▼
┌──────────────┐    ┌──────────────────────────┐
│SimulatorBridg│    │  XCUIBridge              │
│ AX macOS     │    │  TCP DIRECTO al runner   │
│ CGEvent      │    │  127.0.0.1:22087         │
│ simctl       │    └──────┬───────────┬───────┘
└──────────────┘           │ fast path │ fallback
                           │ (warm)    │ (cold)
                           ▼           ▼
                    ┌─────────────┐ ┌──────────────────────┐
                    │ runner xctst│ │ autopilotd (sidecar) │
                    │ TCP :22087  │ │ /tmp/autopilot-X.sock│
                    │ loopback    │ │ - lifecycle (boot)   │
                    └──────┬──────┘ │ - --timeout 0        │
                           │        │ - no idle-shutdown   │
                           │        └──────────┬───────────┘
                           │                   │ xcodebuild boot
                           ▼                   ▼
                    ┌──────────────────────────┐
                    │ iOS Simulator runtime    │
                    │   AutoPilotRunner.xctest │
                    │   testServe() {          │
                    │     TCP :22087 loopback  │
                    │     dispatch @main       │
                    │     XCUIApplication.*    │
                    │   }                      │
                    └──────────────────────────┘
```

### Arquitectura crítica (optimización Maestro-like)

Desde la versión v0.X+, `XCUIBridge` habla **directamente TCP** a `127.0.0.1:22087` (el puerto del runner xctest), **saltando al daemon como proxy**.

- **Fast path (warm)**: connect TCP 100ms, ida+vuelta ~430ms por tap
- **Cold fallback**: si TCP falla, el cliente conecta al daemon vía Unix socket → daemon dispara `boot` del runner (~10-45s) + forwardea el call
- **Siguiente call**: TCP directo está UP → fast path otra vez

El daemon queda **solo para lifecycle** (boot/stop/status del runner). No es proxy de datos.

---

## Componentes

### `HybridBridge.swift` (AutoLibiOS)
Wrapper sobre dos `DeviceBridge`. Cada método escalable intenta `fast` primero; en `BridgeError.elementNotFound` reintenta con `deep`. Métodos no escalables (launch, simctl, biometric) van siempre por fast.

- `public init(fast: DeviceBridge, deep: DeviceBridge)`
- `public func stats() -> String` — imprime contadores `fast=N deep=N escalations=N`

### `XCUIBridge.swift` (AutoLibiOS)
Cliente **directo al runner** en `127.0.0.1:22087` (TCP AF_INET), con fallback a Unix socket al daemon (`/tmp/autopilot-<udid>.sock`) si el runner no responde (cold path: daemon bootea el runner).

Protocolo JSON línea por línea (mismo formato que `AgentBridge` en Android). Implementa hot-path de `DeviceBridge`; métodos no implementados tiran `.unknown("not implemented in XCUI")` para que el híbrido caiga al fast-path.

API pública adicional:
- `list(type: String) throws -> [[String: Any]]` — typed query rápida (buttons, labels, textfields, cells, switches, links, images, navbars, all)

Env var de debug: `AUTO_BRIDGE=simulator|xcui|hybrid` — por defecto `hybrid`.

### `autopilotd` (cli/Sources/Daemon/)
Ejecutable sidecar. Mantiene el runner xctest vivo entre comandos.

- `main.swift` — CLI `start|stop|status`, PID file en `/tmp/autopilot-<udid>.pid`
- `DaemonServer.swift` — socket Unix server, JSON dispatch, timer de idle
- `RunnerLifecycle.swift` — boot/shutdown del `xcodebuild test-without-building`

Política: si el runner está inactivo más de N segundos (default 120), se apaga el runner pero el daemon sigue vivo. Nueva llamada = runner se rearma lazy.

### `AutoPilotRunner.xctest` (runner/AutoPilotRunner/)
Bundle XCTest precompilado. Un único `testServe()` que:
1. Abre TCP server en `127.0.0.1:22087` (loopback dentro del sim).
2. `XCTWaiter` infinito → el test nunca termina hasta recibir `quit`.
3. Cada comando se despacha al main thread (XCUIApplication requiere main).

Fuente:
- `RunnerServer.swift` — accept loop + JSON dispatch
- `RunnerHandlers.swift` — 15 endpoints: ping, tree, tap, typeText, waitFor, screenshot, launch, terminate, exists, search, clear, longPress, doubleTap, scroll, swipe, hideKeyboard
- `RunnerSerialization.swift` — `XCUIElement` → dict compatible con `ElementIndexShared`
- `AutoPilotRunnerTests.swift` — entry point, lee `AUTOPILOT_RUNNER_PORT` y `AUTOPILOT_RUNNER_TIMEOUT` del env

### `RunnerInstaller.swift` (AutoLibiOS)
Instala el runner precompilado en `~/.autopilot/runner/` e invoca `simctl install`. Usa hash SHA256 para saltar reinstalación cuando el bundle no cambió. Genera `.xctestrun` plist con `PropertyListSerialization` para que los paths absolutos sean los correctos en la máquina actual.

---

## Protocolo daemon ↔ runner

JSON línea por línea, terminador `\n`. Idéntico a `AgentBridge.swift` (Android).

**Request:**
```json
{"method":"tap","params":{"target":"General"}}
```

**Response OK:**
```json
{"ok":true,"result":{"tapped":"General"}}
```

**Response error:**
```json
{"ok":false,"error":"element not found: Foo"}
```

Métodos del runner:
| Método | Params | Devuelve |
|---|---|---|
| `ping` | — | `"pong"` |
| `tree` | — | `{tree: {...}}` árbol completo (lento, ~13s) |
| `list` | `type` (all/buttons/labels/textfields/cells/switches/links/images/navbars) | `{items: [...], count, type}` — rápido (~1s) |
| `search` | `query` | `{matches: [...], count}` |
| `exists` | `target` | `{exists: bool}` |
| `tap` | `target` (+ opcional `role`, `within`) | `{tapped}` |
| `longPress` | `target`, `duration` | `{longPressed}` |
| `doubleTap` | `target` | `{doubleTapped}` |
| `clear` | `target` | `{cleared}` |
| `typeText` | `text` (+ opcional `target`) | `{typed: N}` |
| `scroll` | `direction` (+ opcional `target`) | `{scrolled}` |
| `swipe` | `direction` | `{swiped}` |
| `waitFor` | `target`, `timeout` | `{found, target}` |
| `screenshot` | `path` (opcional) | `{saved, size}` o `{base64, size}` |
| `launch` | `bundleId`, `envVars` | `{launched}` |
| `terminate` | `bundleId` | `{terminated}` |
| `hideKeyboard` | — | `{keyboard: "dismissed"}` |
| `quit` | — | cierra el server |

---

## Política de escalada (v1)

Inicial, simple:

```swift
try escalate("tap",
    fast: { try self.fast.tap(target: target) },
    deep: { try self.deep.tap(target: target) })
```

Si `fast` tira `BridgeError.elementNotFound`, se reintenta con `deep`. Cualquier otro error se propaga del fast sin reintentar.

**Métodos que escalan:** `tap`, `longPress`, `doubleTap`, `clear`, `scroll`, `search`, `scrollTo`, `copyTextFrom`.

**Métodos que nunca escalan** (siempre fast): `launchApp`, `terminateApp`, `screenshot`, `installApp`, biometric, simctl, keyboard, orientation, location, recording. Son operaciones de sistema donde XCUI no aporta valor.

**Futura iteración** (fuera de v1): heurísticas basadas en contexto. Por ejemplo, si el script dice `tap[navbar] X`, ir directo a deep sin pasar por fast. O cache de "este target históricamente es deep" para evitar roundtrips fallidos.

---

## Cold boot del runner

Primera vez en una sesión: ~5–45s dependiendo del simulador y si la compilación está cacheada. Pasa una vez por sesión del daemon — llamadas siguientes son warm.

Breakdown típico:
- `xcodebuild test-without-building` parse xctestrun: ~2s
- `simctl install` del runner en el sim: ~1–3s
- Launch del runner app + XCTest bootstrap: ~3–5s
- `XCUIApplication` handshake inicial: ~1–2s

Con daemon persistente, después del primer comando el runner queda vivo y responde sub-segundo.

---

## Flags críticos de xcodebuild

En Xcode 26, `xcodebuild test-without-building` clona el simulador por defecto para tests paralelos. **Cuando el test termina, el clone se destruye y arrastra el sim principal**. El fix es forzar ejecución serial:

```swift
// En RunnerLifecycle.swift
proc.arguments = [
    "xcodebuild", "test-without-building",
    "-xctestrun", xctestRunPath,
    "-destination", "platform=iOS Simulator,id=\(udid)",
    "-only-testing:\(testID)",
    "-parallel-testing-enabled", "NO",
    "-disable-concurrent-destination-testing",
    "-maximum-concurrent-test-simulator-destinations", "1"
]
```

Sin estos flags, el sim se apaga después de cada ciclo del daemon.

---

## Debug manual

### 1. Arrancar daemon contra un runner compilado

```bash
# Modo recomendado: helper que hace pre-warm automático
./scripts/demo/start-daemon.sh start   # --timeout 0 + pre-warm del runner

# O manualmente:
auto runner install path/to/Runner.app
auto daemon start --udid <UDID> --timeout 0   # 0 = runner inmortal
auto daemon status
```

**`--timeout 0`** significa que el runner nunca se apaga por inactividad mientras el daemon esté vivo. Pagás el cold boot una sola vez por sesión.

### 2. Forzar bridge específico

```bash
# Fast únicamente (como antes de XCUI)
AUTO_BRIDGE=simulator auto tap "General"

# Deep únicamente
AUTO_BRIDGE=xcui auto tap "Guardar"

# Híbrido (default, fast + escalada a deep)
auto tap "Guardar"
```

### 3. Hablar directamente con el runner

Mientras el daemon + runner están vivos:

```bash
# Ping al daemon
echo '{"method":"ping"}' | nc -U /tmp/autopilot-<UDID>.sock

# Status del runner
echo '{"method":"status"}' | nc -U /tmp/autopilot-<UDID>.sock

# Cualquier método del runner pasa a través del daemon
echo '{"method":"tree"}' | nc -U /tmp/autopilot-<UDID>.sock
```

### 4. Tear down limpio

```bash
auto daemon stop --udid <UDID>
# Elimina PID file + socket + mata runner con SIGTERM→SIGKILL
```

---

## Comandos CLI

| Comando | Qué hace | Velocidad típica |
|---|---|---|
| `auto tree` | árbol AX macOS (fast) | ~300ms |
| `auto tree deep` | árbol XCUI completo (lento) | ~10-13s |
| `auto tree full` | fast + deep side-by-side | ~10-13s |
| `auto list` | elementos interactivos (buttons+fields+cells+switches+links) | ~1s |
| `auto list buttons` | solo botones | ~500ms-1s |
| `auto list labels` / `statictexts` | solo textos estáticos | ~500ms |
| `auto list textfields` | inputs | ~500ms |
| `auto list cells` / `switches` / `links` / `images` / `navbars` | filtros individuales | ~500ms |
| `auto exists "X"` | bool si X existe | ~500ms |
| `auto tap "X"` | tap híbrido (fast + escalación si falla) | ~300ms warm / ~1.6s cuando escala |
| `auto daemon start/stop/status` | lifecycle del sidecar | instantáneo |
| `auto runner install/status` | bundle del runner xctest | ~3s |

---

## Benchmarks (Xcode 26, iPhone 17 iOS 26.3, tap "General" en Settings)

```
SimulatorBridge (baseline, fast):   300ms
HybridBridge   (default):           355ms   (+3% overhead del wrapper)
XCUIBridge     (directo, warm):     430ms   (con TCP directo, queries tipadas)
XCUIBridge     (cold boot):         10-45s  (una vez por sesión del daemon)
```

**Exploración de UI (evita `tree deep` completo):**

```
tree deep (árbol completo):     13000ms
list all (solo interactivos):    1250ms   (10x más rápido)
list buttons:                    1000ms
```

El HybridBridge opera a velocidad de SimulatorBridge en el 80–90% de casos. Solo paga el overhead de XCUI cuando el elemento realmente no está en AX.

### Por qué `list` es 10x más rápido que `tree deep`

- **`tree deep`**: pide el snapshot completo + por cada nodo (~500) extrae 7 atributos via XPC → **3500+ XPC calls**.
- **`list buttons`**: `app.buttons` es una `XCUIElementQuery` tipada que solo materializa botones. Usa `XCUIElement.snapshot()` para batch-fetch todos los atributos en 1 XPC por elemento → **~100 XPC calls** para ~20 botones.

---

## Archivos clave

| Pieza | Path |
|---|---|
| HybridBridge | `cli/Sources/AutoLibiOS/HybridBridge.swift` |
| XCUIBridge (cliente) | `cli/Sources/AutoLibiOS/XCUIBridge.swift` |
| RunnerInstaller | `cli/Sources/AutoLibiOS/RunnerInstaller.swift` |
| autopilotd main | `cli/Sources/Daemon/main.swift` |
| DaemonServer | `cli/Sources/Daemon/DaemonServer.swift` |
| RunnerLifecycle | `cli/Sources/Daemon/RunnerLifecycle.swift` |
| Runner xctest | `runner/AutoPilotRunner/` |
| Factory `makeBridge()` | `cli/Sources/CLI/main.swift` |

---

## Limitación resuelta

`CLAUDE.md` histórico decía:

> SwiftUI NavigationBar buttons no se exponen via macOS AX (AXChildren=[0])

Esta limitación aplica solo al fast-path (`SimulatorBridge`). Con el HybridBridge default, esos botones ahora **sí se resuelven** porque la escalada automática activa XCUIBridge, que dentro del runtime del simulador ve la NavigationBar como elemento queryable con identifier y children.
