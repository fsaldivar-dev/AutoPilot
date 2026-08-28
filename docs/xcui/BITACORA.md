# Bitácora — XCUI / HybridBridge / segundo motor iOS

Diario de laboratorio crudo de la investigación y construcción del segundo motor iOS (XCTest runner dentro del simulador). Sirve como referencia histórica para el [Capítulo 15 — El segundo motor](../libro/15-el-segundo-motor.md).

El formato es cronológico, sin editar. Los capítulos del libro se basan en estas entradas pero pulidas.

---

## Sesión 2026-04-08 — Spike: validar hipótesis de NavBar SwiftUI

### Hipótesis

`XCUIApplication` corriendo dentro de un runner XCTest ve `NavigationBar` como elemento queryable, mientras que el `AXUIElement` de macOS externo la aplana a un `AXGroup` opaco sin children.

Si la hipótesis pasa, todo el proyecto (HybridBridge + XCUIBridge + daemon + runner) tiene sentido. Si falla, hay que replantear.

### Setup

- Xcode 26.3 (17C529), iPhone 17 sim UDID `0A2BAB42-8475-4C3C-A44E-842C28ECA179`, iOS 26.3.1
- Agregué 2 tests al target `Test AutomatitacionUITests` existente del demo:
  - `testAutoPilotSpikeNavBarVisibility` — lanza Settings, hace `app.debugDescription`, imprime árbol
  - `testAutoPilotSpikeServeLoopback` — gated con `AUTOPILOT_SPIKE_SERVE=1`, levanta TCP server en 127.0.0.1:22087 con XCTWaiter infinito

### Resultado

Test pasó en 8.3s (build + test). Del dump de XCUIApplication:

```
Attributes: Application, pid: 98534, label: 'Configuración'
Element subtree:
 →Application, label: 'Configuración'
    Window (Main), {0.0, 0.0, 402.0, 874.0}
      ...
        NavigationBar, identifier: 'Configuración', {0.0, 62.0, 402.0, 106.0}
          StaticText, label: 'Configuración', {16.0, 119.7, 224.7, 40.7}
```

En paralelo, `auto tree` (SimulatorBridge actual) contra la misma Settings:

```
AXGroup [808,171 402x874]
  AXHeading label="Configuración" [824,290 224x40]
  AXButton label="Cuenta de Apple, ..." id=com.apple.settings.primaryAppleAccount
  ...
```

**Confirmado**: XCUIApplication expone `NavigationBar` como tipo de elemento propio con identifier y children. SimulatorBridge aplana a `AXHeading` + `AXButton`s sueltos sin el contenedor NavigationBar. Hipótesis válida.

### Resto del plan

Quedó armado el plan `.claude/plans/tranquil-knitting-truffle.md` con 5 olas:
1. Foundations (spike + daemon + installer) — estado: spike hecho
2. Runner endpoints + CI
3. XCUIBridge cliente + docs
4. HybridBridge + factory
5. E2E + benchmark

### Observaciones

- Runner xctest tarda ~43s en responder al primer comando (cold boot de xcodebuild + sim handshake + XCTest bootstrap).
- `XCTWaiter.wait(for: [done], timeout: 600)` aguanta el main thread infinitamente. El patrón WDA funciona.
- El xctest bundle se instala en el sim como `dev.autopilot.test.ExploreaUITests.xctrunner` — una app más.

---

## Sesión 2026-04-15 AM — Build de daemon + RunnerInstaller

### Lo que salió fácil

- `cli/Sources/Daemon/main.swift` con PID file, signal handlers (`SIGTERM`/`SIGINT`/`SIGHUP`), socket Unix en `/tmp/autopilot-<udid>.sock`. Patrón copiado de `AgentBridge.swift` de Android pero invertido (servidor en Mac, no en device).
- Pre-check del `AF_UNIX` `sun_path` máximo 104 bytes con `strncpy` y NUL explícito. El `strcpy` directo fue flaggeado en review.
- `RunnerInstaller.swift` con SHA256 hash check para saltar reinstalación. `simctl install` + regeneración del `.xctestrun` con paths absolutos via `PropertyListSerialization`.

### Tropiezo

`RunnerInstaller.regenerateXCTestRun()` genera un `.xctestrun` en formato **v1** (FormatVersion=2, SchemaVersion=1). Xcode 26 rechaza:

```
xcodebuild: error: Failed to build workspace temporary with scheme Transient Testing.:
Dictionary does not contain key "TestConfigurations" with expected type
```

Xcode 26 exige formato v2 con una estructura `TestConfigurations` array de configuraciones. Escribirlo a mano con `PropertyListSerialization` es doloroso.

**Workaround temporal**: agregué env var `AUTOPILOT_RUNNER_XCTESTRUN` al `RunnerLifecycle.swift`. Permite apuntar al `.xctestrun` que Xcode ya generó en DerivedData al compilar (con `xcodebuild build-for-testing`). El generador v2 propio queda pendiente.

---

## Sesión 2026-04-15 PM — Primer E2E con daemon + runner

### Arquitectura inicial

```
auto → Unix socket → autopilotd → TCP :22087 → runner xctest
     ← Unix socket ← autopilotd ← TCP :22087 ←
```

Todo pasa por el daemon. El daemon reenvía.

### Crash número uno: sim se apaga después de cada ciclo

```
$ auto daemon start → ✓
$ auto tap "General" → ✓ (440ms)
$ auto tap "Settings" → Error: No simulator window found
$ xcrun simctl list devices booted → (none)
```

Debug: después del primer tap (que triggerea cold boot del runner), el `xcodebuild test-without-building` **clona el simulador**. Cuando el test termina — por `quit` o por timeout del XCTWaiter — el clone se destruye y **mata el sim principal** en el proceso.

No encontré nada en release notes de Xcode 26. Probando flags:

```swift
proc.arguments = [
    "xcodebuild", "test-without-building", ...
    "-parallel-testing-enabled", "NO",
    "-disable-concurrent-destination-testing",
    "-maximum-concurrent-test-simulator-destinations", "1"
]
```

Con los tres, el sim del usuario sobrevive. Sin uno solo de ellos, muere. Undocumented.

### Crash número dos: NSInternalInconsistencyException, main thread

```
*** Assertion failure in -[XCUIApplication _launchUsingXcode:...]
-[XCUIApplication _launchUsingXcode:withoutAccessibility:launchURL:] must be called on the main thread
```

Server TCP en `DispatchQueue.global(qos: .userInitiated)`, handlers llaman `XCUIApplication.launch()` → crash. Todas las operaciones XCUI tienen esta assertion.

Fix: `dispatchOnMain()` con semáforo:

```swift
private func dispatchOnMain(_ block: @escaping () -> String) -> String {
    if Thread.isMainThread { return block() }
    var result = ""
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        result = block()
        semaphore.signal()
    }
    semaphore.wait()
    return result
}
```

Funciona porque `XCTWaiter.wait()` del `testServe()` pumpea el RunLoop del main — los bloques se despachan, ejecutan, liberan el semáforo. Invariante silenciosa de XCTest.

### Benchmark inicial (con daemon como proxy)

```
tap General warm:  ~1500ms
tap cold:          ~5800ms (primer call post-boot)
tree deep:         ~13000ms
```

1500ms warm es 3-5x peor que Maestro. Pero al menos funciona.

---

## Sesión 2026-04-16 AM — Fixes de estabilidad

### `resolveApp` stale tras terminate externo

Si el cliente hace `auto terminate com.apple.Preferences` y después `auto tap "X"` contra la misma app relanzada, el runner tiene `activeApp` apuntando al proceso muerto anterior. Resultado: "element not found" silencioso aunque el elemento exista en la nueva instancia.

Fix: `resolveApp(params:)` en `RunnerHandlers`:

```swift
if activeApp.state == .runningForeground {
    return activeApp
}
// Stale — rebuild
if let bid = activeBundleId {
    let a = XCUIApplication(bundleIdentifier: bid)
    activeApp = a
    return a
}
```

Y `handleLaunch()` registra `activeBundleId` para poder reconstruir sin argumentos.

### `handleLaunch` usa activate() si ya está en foreground

Evita kill-and-restart cuando la app ya está corriendo:

```swift
if targetApp.state == .runningForeground {
    targetApp.activate()  // trae al frente
} else {
    targetApp.launch()    // full relaunch
}
```

Baja tap de `launch` de 500ms a ~57ms cuando la app ya está abierta.

### Bench verificación

```
call 1: 467ms  (warm)
call 2: 424ms
call 3: 437ms
call 4: 434ms
call 5: 429ms
```

Estable en ~430ms. Demo corrió full contra Explorea NewEntryView: el `tap "Guardar"` que antes fallaba ahora escala automáticamente y tapea en ~1.6s (300ms de fast fail + 430ms de XCUI warm + overhead).

---

## Sesión 2026-04-16 PM — Paridad con Maestro

### Plan

1500ms por tap warm no es competitivo. Maestro hace 300-500ms. Dos hipótesis para la diferencia:

1. El daemon como proxy serializa/deserializa dos veces por cada request (overhead). 
2. `findElement` hace `descendants(matching: .any).matching(predicate)` — escaneo lineal sobre todo el árbol.

### Cambio 1: TCP directo al runner

`XCUIBridge.swift` antes conectaba a Unix socket del daemon. Nuevo: conecta directo a `127.0.0.1:22087` (runner), fallback a daemon Unix socket solo si el runner no responde (para triggerear auto-boot).

```swift
// Fast path
if let fd = connectTCP(host: "127.0.0.1", port: 22087) {
    return try exchange(fd: fd, ...)
}
// Cold fallback
guard let daemonFD = connectDaemonUnixSocket() else { throw ... }
return try exchange(fd: daemonFD, ...)
```

Resultado:
```
tap warm antes:   1500ms
tap warm después:  430ms  (3.5x)
```

### Cambio 2: queries tipadas en findElement

Agregué fast-path en `findElement(target:, params:)`:

```swift
// Antes de ir al predicate-scan, intentar queries tipadas:
for q in [app.buttons, app.staticTexts, app.textFields, ...] {
    let byLabel = q[query]   // O(1), lazy
    if byLabel.exists { return byLabel }
}
```

`app.buttons["Login"]` es O(1) porque XCTest usa estructura indexada. `descendants(matching: .any).matching(predicate)` es O(N) con N full snapshots.

### Cambio 3: `auto list` (comando nuevo)

`tree deep` tardaba ~13s porque serializaba ~500 nodos × 7 atributos = 3500 XPC calls al sim. Cada acceso a `element.label`, `element.value`, etc es un XPC separado.

Agregamos `handleList(type:)` en el runner:

```swift
case "buttons": queries = [("Button", app.buttons)]
case "labels":  queries = [("StaticText", app.staticTexts)]
...

for (role, q) in queries {
    for i in 0..<q.count {
        let snap = try q.element(boundBy: i).snapshot()  // 1 XPC por elemento
        items.append([role, snap.label, snap.identifier, ...])
    }
}
```

`XCUIElement.snapshot()` hace un XPC que trae todo cacheado en memoria. Resto son reads de struct.

CLI expone:

```bash
auto list buttons        # ~500ms-1s
auto list textfields     # ~500ms
auto list                # todos los interactivos (~1s)
```

Contra `tree deep` (13s), es 10x más rápido y devuelve exactamente lo que el usuario necesita (elementos tapeables).

### Idb

Intentamos idb_companion de Facebook antes del approach TCP directo. Más rápido que XCTest (50-200ms warm, vs 430ms), pero:

```bash
$ brew install facebook/fb/idb-companion
Error: Your Command Line Tools are too outdated.
You should download the Command Line Tools for Xcode 26.3.
```

CLT en 16.3, Xcode en 26.3. Brew rechaza. Compilar desde source requiere XcodeGen + gRPC + SPM plugins. Cadena de dependencias frágil. Descartado por ahora.

Si las CLT se destraban en el futuro, reemplazar `XCUIBridge` por `IdbBridge` sería trivial — mismo `DeviceBridge` protocol, solo cambia el transport.

### Runner inmortal

Daemon default tenía `--timeout 120` (apagar runner tras 2 min sin uso). Si el usuario no hacía nada en 2 min y después hacía `auto tap`, pagaba cold boot de nuevo.

Cambio: `--timeout 0` ahora significa "runner inmortal mientras daemon vive". El launcher `start-daemon.sh` setea `--timeout 0` + pre-warm (una llamada `auto tree` inmediata al arrancar el daemon).

Resultado: **pagás ~10-45s cold boot UNA VEZ al arrancar el daemon**. Todas las llamadas siguientes son warm.

---

## Sesión 2026-04-17 — CI + merge

### El CI rompió en macos-15

`Build XCTest runner bundle` job fallaba en GitHub Actions:

```
xcodebuild: error: Unable to find a destination matching the provided destination specifier
```

macos-15 runners de GitHub tienen **Xcode 16.4** (no Xcode 26 como mi máquina). El demo xcodeproj fue creado con Xcode 26 y tenía `IPHONEOS_DEPLOYMENT_TARGET = 26.0`. Xcode 16.4 solo tiene SDK iOS 18.x — ningún simulador del runner era compatible.

Fix: bajé `IPHONEOS_DEPLOYMENT_TARGET = 26.0` → `17.0` en los 4 targets del pbxproj. El runner xctest no usa APIs iOS 26-specific; iOS 17 alcanza.

CI verde post-fix:
```
✓ Build XCTest runner bundle   2m10s
✓ build-and-test                41s
✓ GitGuardian Security Checks    1s
✓ e2e                          4m38s
```

### Merge

PR #89 — 8 commits (7 features + 1 CI fix). 4/4 checks. Mergeado.

---

## Sesión 2026-08-28 — El `.xctestrun` v2 nativo, y por qué el motor no era distribuible (#355)

### Objetivo

Preparar la v0.1.0 para Homebrew. El motor deep no podía distribuirse y había que
entender exactamente por qué.

### El bloqueo, visible en el disco

`~/.autopilot/runner/` contenía esto:

    Debug-iphonesimulator -> /Users/…/Library/Developer/Xcode/DerivedData/
                             Test_Automatitacion-clyktavlnfgpuvalfmjgiehwepnn/…

Un symlink al DerivedData, con un hash de proyecto que solo existe en la máquina
que lo generó. Por eso funcionaba en el Mac de siempre y en un clon limpio no. No
era falta de firma —`RunnerInstaller` no tiene ni una referencia a `codesign`, y
los bundles de simulador los firma la toolchain ad-hoc— sino una ruta irrepetible.

### Cinco bugs encadenados

Cada uno tapaba al siguiente. Solo el primero estaba en el roadmap.

1. **Forma v1 declarada como versión 2.** El generador escribía `FormatVersion: 2`
   pero con los targets colgando de la raíz. Xcode lee la versión, busca
   `TestConfigurations` y falla. La estructura correcta salió de leer un
   `.xctestrun` real generado por Xcode, no de documentación.

2. **`UITargetAppPath` ausente.** Parecía correcto omitirlo: el runner se adjunta
   en ejecución con `XCUIApplication(bundleIdentifier:)`, no a una app fija.
   `xcodebuild` lo rechaza igual — `UITargetAppPath should be provided`. Es un
   requisito estático, no funcional.

3. **`TestHostBundleIdentifier` hardcodeado** a `dev.autopilot.runner.xctrunner`
   cuando el real es `dev.autopilot.test.ExploreaUITests.xctrunner`. Ese id lo fija
   el proyecto Xcode que compila el runner: para algo distribuible no se puede
   suponer. Ahora se lee del `Info.plist` del bundle.

4. **`libXCTestBundleInject` inyectada en un runner de UI.** El síntoma era

       'Cannot initiate shared session more than once.'
         en +[XCTRunnerDaemonSession initiateSharedSessionWithCompletion:]

   y parecía una sesión previa colgada. No lo era. En el backtrace del crash
   `_XCTestMain` aparece **dos veces en el mismo stack**: una desde
   `_XCTRunnerRunTests` (el propio Runner.app) y otra desde
   `__RunTests_block_invoke_2` de la dylib inyectada. Dos arranques en el mismo
   proceso.

   Esa inyección es para tests *unit* alojados en la app bajo prueba, donde el host
   no sabe nada de XCTest. Un runner de UI ya carga su bundle solo. Contrastado
   contra el `.xctestrun` de Xcode: su target unit la lleva, el de UI no.

   Hipótesis descartada por el camino: "el runner es de julio (17F41) y Xcode es
   17F42". Plausible y falsa. No hizo falta recompilar nada.

5. **`-only-testing` con el nombre de target fijo.** Aun con el plist correcto, el
   daemon no levantaba el runner: pasaba
   `-only-testing:AutoPilotRunnerUITests/AutoPilotRunnerTests/testServe`, pero el
   target real lo nombra el proyecto Xcode (`Test AutomatitacionUITests`).
   xcodebuild no encontraba el test, no seleccionaba ninguno y salía al instante —
   por eso el síntoma era "runner not responding" **sin que existiera un proceso**.

   La selección ya vive en `OnlyTestIdentifiers` dentro del `.xctestrun`.
   Duplicarla en la línea de comandos solo añadía una forma de contradecirse.

### Un mensaje de error que costó tiempo

`BootError.runnerNotResponding` decía *"after 15s"* mientras el bucle esperaba 60s
(300 × 200ms). Mandó a mirar el timeout en vez de la causa. Un número inventado en
un mensaje de error es peor que no dar número.

### El falso negativo del router

Probando el motor ya reparado contra una app de terceros apareció algo peor que un
crash: `auto exists "TEXTO"` contestaba **`NO` en 4ms con el texto en pantalla**.

Cadena: el observer ve la geometría de SwiftUI —los `AXGroup` salen con sus frames
exactos, `[16,706 52x14]`— pero no extrae el texto de los `Text`. En
`LegacyBridgeAdapter`, `.search` devolvía `.elements([])` como **éxito**. Y el
router solo pasa al siguiente backend ante `elementNotFound` o `connectionFailed`,
así que un éxito vacío lo daba por bueno.

El "cero" del observer significaba *"no sé mirar esto"* y se propagaba como
*"no está"*.

Arreglado sin tocar el router: `.search` vacío lanza `elementNotFound` —entra el
escalado que ya se aplica a `tap`— y `exists` lo captura para seguir respondiendo
booleano. (Al hacerlo se rompió `exists`, que pasó a dar error duro en vez de `NO`;
hizo falta el catch.)

Coste medido. El camino rápido, cuando encuentra, no cambia:

| caso | antes | ahora |
|---|---|---|
| texto SwiftUI presente | `NO` 4ms ← falso | `YES` 20ms |
| ausente, runner caliente | `NO` 4ms | `NO` 47ms |
| ausente, runner frío | `NO` 4ms | `NO` 2384ms |

`waitUntilGone` se apoya en negativos repetidos, así que con runner frío baja la
resolución del sondeo.

### Verificación

    xcodebuild test-without-building  ->  Test Case '…testServe' started
    daemon auto-boot                  ->  runner: ready, 1 proceso xctrunner
    auto tap                          ->  Tapped 'Regresar a CameraTestApp'
    E2E contra app de terceros        ->  YES 23ms / hot-swap YES 6ms / obsoleto NO 47ms
    suite completa                    ->  463 tests, 0 fallos

### Queda pendiente

- El `Runner.app` sigue sin viajar en el release: hay que compilarlo con
  `build-for-testing`. Con esto arreglado ya tiene sentido publicarlo como asset;
  antes no, porque el `.xctestrun` generado no servía.
- `auto tap` tardó **17.7s** con el runner ya listo. Sin explicación; no encaja con
  los ~13s documentados de `tree deep`.
- El observer no lee texto de SwiftUI. El arreglo hace que no mienta, pero no le da
  la capacidad. Si la ganara, el escalado dejaría de dispararse en el caso común.
- Probado solo en iPhone 16 Pro / iOS 18.5 / Xcode 26.5 / arm64.

---

## Hallazgos clave (resumen)

1. **SwiftUI `ToolbarItem` en `NavigationBar` aparecen como `AXGroup` opaco** al AX macOS externo en iOS 26 / Xcode 26. Parece un regression vs iOS 17 (antes sí se exponían). Nadie lo documenta.

2. **Xcode 26 default clona el sim para tests** y destruye el clone al final del ciclo, matando el sim padre. Fix: tres flags `-parallel-testing-enabled NO` + `-disable-concurrent-destination-testing` + `-maximum-concurrent-test-simulator-destinations 1`. Undocumented.

3. **`XCUIApplication` requiere main thread**. Si el servidor corre en background, dispatchar al main con semáforo. El `XCTWaiter.wait()` pumpea el RunLoop — sin eso, deadlock.

4. **`XCUIElement.snapshot()` es la diferencia entre 60s y 2s** para árboles completos. Acceder a propiedades una-por-una es 1 XPC cada una.

5. **Queries tipadas (`app.buttons[x]`) son O(1) vs O(N)** de `descendants(matching: .any).matching(predicate)`.

6. **El daemon como proxy mata latencia**. Saltar el daemon para hot-path baja tap de 1500ms → 430ms (3.5x) con el mismo código de handler.

7. **`--timeout 0` + pre-warm** convierte cold boot de "en cada llamada cuando muera el runner" a "una sola vez por sesión del daemon".

8. **idb sería mejor técnicamente** pero el setup (CLT sincronizadas con Xcode) es demasiado frágil para distribución.

9. **GitHub macos-15 runners tienen Xcode 16.4, no 26**. Los proyectos Xcode 26 no buildan si el deployment target es iOS 26+.

10. **Formato `.xctestrun` v1 vs v2**. Xcode 26 exige v2 con `TestConfigurations`. ~~Generarlo a mano es complicado; más simple apuntar al DerivedData.~~ **Revisado 2026-08-28 (#355):** apuntar al DerivedData es justo lo que impedía distribuir el motor —la ruta lleva un hash de proyecto irrepetible—. Generarlo a mano resultó directo en cuanto se leyó el esquema de un `.xctestrun` real en vez de intentar deducirlo. Lo difícil no era el plist.

11. **En un runner de UI NO se inyecta `libXCTestBundleInject`**. El Runner.app ya carga su bundle; inyectarla además arranca los tests dos veces y aborta con `Cannot initiate shared session more than once`. La pista está en el backtrace: `_XCTestMain` dos veces en el mismo stack. Esa dylib es para tests unit alojados en la app bajo prueba.

12. **La selección de test va en el `.xctestrun`, no en la línea de comandos**. `OnlyTestIdentifiers` existe para eso. Duplicarla con `-only-testing` solo crea una forma de que las dos se contradigan — y el fallo se manifiesta como "runner not responding" sin que llegue a existir un proceso.

13. **Un backend que devuelve "cero resultados" no está respondiendo, está callándose**. Si no distingue "miré y no está" de "no sé mirar esto", el router se para en él y propaga un falso negativo. Lanzar `elementNotFound` es lo que permite escalar. Un `exists` rápido y equivocado es peor que uno lento y correcto.

---

*Para la narrativa pulida y las lecciones consolidadas: [Capítulo 15 — El segundo motor](../libro/15-el-segundo-motor.md).*

*Para el detalle técnico (protocolo, métodos del runner, benchmarks): [docs/ios/XCUI-BRIDGE.md](../ios/XCUI-BRIDGE.md).*
