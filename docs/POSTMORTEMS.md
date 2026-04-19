# AutoPilot — Post-mortems

Casos de estudio de decisiones que no funcionaron como esperábamos, y qué aprendimos. El objetivo no es asignar culpa sino **documentar el razonamiento fallido** para que no lo repitamos (o lo repitamos con más contexto).

Cada post-mortem tiene: contexto → hipótesis inicial → qué pasó → root cause → qué aprendimos.

---

## PM-001 — Event-driven `waitFor` via AXObserver (revertido)

**Período:** marzo-abril 2026 · **Issue:** [#79](https://github.com/fsaldivar-dev/AutoPilot/issues/79) · **Resolución:** parcial en PR #109

### Contexto

`waitFor` hacía poll cada 500ms, donde cada ciclo llamaba `bridge.search(query:)` → tree dump recursivo (~30ms). Para flows con transiciones breves (permission dialogs que aparecen <500ms), perdíamos el dialog por timing.

Idea intuitiva: **reemplazar el poll por AXObserver**. macOS `AXObserver` entrega notifications cuando el AX tree cambia. Re-check la condición en cada evento, con un safety floor de 100-200ms. Esperado: latencia <100ms en lugar de 500ms.

### Hipótesis

- Los eventos AX son raros y puntuales
- Cada evento trigger un re-check era gratis
- Poll queda como fallback si observer detached

### Qué pasó

**50% pass rate** (3/6 runs) vs 100% con poll antiguo. Flujos que antes funcionaban empezaron a timeout.

### Root cause

**Oversampling de eventos** + **query cara**:

1. El simulator emite **20-30 eventos AX por segundo** durante init de una app. No son raros — son una cascada.
2. Cada evento disparaba un `bridge.search()` de **~30ms** (tree dump recursivo, serialización de ~120 atributos AX).
3. Con eventos a 20-30Hz y dumps de 30ms cada uno, **gastábamos ~100% CPU dumpeando**, contendiendo con el simulator mismo.
4. Transiciones breves (un dialog de 200ms) eran **coalescidas o skipeadas** por el simulator antes de que nuestro next poll las capturara.

El poll de 500ms **"funcionaba por accidente"** — su lentitud daba breathing room al simulator para completar sus transiciones atómicamente.

### Qué aprendimos

> **No hay performance gratis en sistemas compartidos.** Aumentar sample rate sin bajar cost-per-sample te hace perder más de lo que ganás.

Para un retry serio hay que resolver los dos bloqueos **antes** de tocar el observer:

1. **Query más barata que `bridge.search()`** — un método tipo `findByLabelFast(String) -> Bool` de ~5ms, no ~30ms.
2. **Event debouncing agresivo** — coalescer bursts de eventos a máximo 1 re-check cada 300-500ms.

### Resolución parcial (PR #109)

Tras el aprendizaje, el fix no fue event-driven puro sino **híbrido**:

- Nuevo método `DeviceBridge.existsFast(label:)` — shallow query sin full tree (~5-10ms)
- `waitFor` hace poll 100ms (era 500ms) pero con `existsFast` en lugar de `search`
- CPU total similar (5× más polls × 5× más barato por poll)
- Latencia 3.9× mejor: 596ms → 153ms en smoke test

**No es event-driven**, pero logra el objetivo sin el riesgo de oversampling.

---

## PM-002 — Recorder emite `waitFor "<value>"` para text fields

**Período:** marzo 2026 · **Memoria:** `recorder_experiment_findings.md` · **Fix:** commit [`55c1acf`](https://github.com/fsaldivar-dev/AutoPilot/commit/55c1acf)

### Contexto

Recorder semántico (iOS): al grabar, captura cada click + resuelve el AX element → emite `tap "Login"`. Para `waitFor` (elementos no clicables), capturaba el label del elemento estático.

### Hipótesis

El AX `value` de un elemento es un buen identificador — lo usamos como selector si no hay `title` ni `identifier`.

### Qué pasó

En flujos de login:
1. Usuario tipea email → el `UITextField.value` cambia a "fsaldivar@..."
2. Recorder captura la transición → emite `waitFor "fsaldivar@..."`
3. Al reproducir el script en una sesión limpia, el value es `""` — **el waitFor timeout** y el script falla.

**Replay success: 50%.** Factor escala entre 90 líneas grabadas vs 30 líneas útiles. MCP (Multi-Capture Probability) vs AX ratio: 1.26 (26% de pasos emitidos eran basura).

### Root cause

Confusión de **"estado observado ahora"** vs **"propiedad estructural del UI"**:

- `label`, `title`, `identifier` son propiedades del UI design — no cambian entre sesiones.
- `value` es **estado runtime** — cambia con cada sesión.

El recorder trataba los cuatro iguales como selectores de recuperación.

### Qué aprendimos

> **Selector = propiedad que podés predecir antes de correr.** Si el valor viene del usuario o del backend, no es un selector.

Regla aplicada: **nunca usar AX `value` como fallback de selector**. Solo `label`, `title`, `identifier`. Si ninguno existe, fallback a `AXRole` + coordenadas (último recurso).

### Fix aplicado

`SemanticResolver.resolveSelector()` — skip del `value` en fields de texto (AXTextField, AXTextArea, AXSecureTextField).

Tests agregados: `SemanticResolverTests.testTextFieldValueIsNotUsedAsSelector`, `testSecureTextFieldValueIsNotUsedAsSelector`, `testTextAreaValueIsNotUsedAsSelector`.

### Lección transferida

Esta lección aparece **otra vez** en el diseño de ARD-002: el observer in-process tendrá acceso a `UITextField.text` (más completo que AX `value`). Hay que aplicar la misma regla — no usar texto de runtime como selector.

---

## PM-003 — Xcode 26 clona simulador para tests paralelos

**Período:** abril 16 2026 · **Memoria:** `session_2026-04-16_xcui_bridge_complete.md`

### Contexto

Al implementar `XCUIBridge`, el daemon arranca un runner xctest con `xcodebuild test-without-building -destination "platform=iOS Simulator,id=<UDID>"`.

### Hipótesis

xcodebuild corre el test en el simulator especificado por UDID. Simple.

### Qué pasó

Primer test: el simulator **se cerraba** al terminar el test. Click en `auto list` → sim muerto → había que rebootear manual cada vez.

### Root cause

**Xcode 26 cambió el default:** para permitir tests paralelos, `xcodebuild` **clona** el simulator específicado antes de correr el test. Al terminar, **destruye el clon**.

Pero el clone y el original comparten el mismo CoreSimulator device, y destruir el clon **también mata el original**. Bug/feature de Xcode 26 — antes (Xcode 15) no pasaba.

### Qué aprendimos

> **Cambios silenciosos de Apple pueden romper asumpciones que llevaban años funcionando.** Siempre correr matrix de tests contra versiones de Xcode actual y anterior.

### Fix aplicado

Tres flags nuevos al `xcodebuild` que invoca `autopilotd`:

```
-parallel-testing-enabled NO
-disable-concurrent-destination-testing
-maximum-concurrent-test-simulator-destinations 1
```

Los tres son necesarios — quitar cualquiera reintroduce el bug. Documentado en [docs/ios/XCUI-BRIDGE.md](ios/XCUI-BRIDGE.md).

---

## PM-004 — `DYLD_INSERT_LIBRARIES` no funciona en iOS device

**Período:** descubierto en el diseño de ARD-002 (abril 19 2026)

### Contexto

En simulator inyectamos `libAutoPilotCapture.a` (camera mock) via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` al launchear la app con `simctl launch`. Funciona perfecto.

**Hipótesis**: para device físico, el equivalente sería una env var similar pasada al launch.

### Qué pasó

Investigación durante el diseño de ARD-002 reveló:

1. `xcrun devicectl device process launch --env DYLD_INSERT_LIBRARIES=...` **es ignorado** en iOS device por security policy del kernel.
2. Es una **protección explícita** de iOS contra code injection.
3. Solo funciona en jailbroken devices (MobileSubstrate) o via Frida con re-signing.

### Root cause

iOS sandbox bloquea carga de dylibs que no estén en el bundle firmado. `DYLD_INSERT_LIBRARIES` es una env var reconocida por el loader pero **el kernel iOS la strippea** antes del exec() en device real.

Simulator funciona porque corre sobre macOS — el kernel de macOS honra la env var normal.

### Qué aprendimos

> **Simulator != device.** Cualquier feature que dependa de features del kernel macOS (env vars de load, ptrace, etc.) tiene que re-diseñarse para device.

### Fix propuesto (ARD-002)

**Build-time linking** con `-force_load`. La lib queda **dentro** del Mach-O firmado con dev certificate — iOS la trata como código propio de la app. No hay injection externa → nada que bloquear.

Trade-off: requiere source/Xcode project (o re-sign del .ipa). Pero para el caso de uso primario (testing de apps propias), es aceptable.

Ver [docs/rfc/ARD-002-ios-in-process-observer.md](rfc/ARD-002-ios-in-process-observer.md).

---

## PM-005 — `SimulatorBridge.swift` crecimiento a 1964 LOC (debt recognized, then paid)

**Período:** acumulativo durante 2025-abril 2026 · **Fix:** PR #110

### Contexto

El primer `SimulatorBridge.swift` tenía ~400 LOC. Cada feature (camera mock, biometry, files, recording, keychain, permissions, etc.) agregaba métodos a la misma clase.

### Qué pasó

**1964 LOC, 96 funciones, 6 responsabilidades mezcladas:**

- AX tree queries y element search
- CGEvent input (tap, swipe, drag)
- xcrun simctl wrappers (install, launch, biometry, files)
- AppleScript menu interactions
- Camera mock + DYLD injection
- Screen recording

Síntomas:
- Changes in unrelated features causaban merge conflicts
- Tests unitarios prácticamente imposibles (clase gigante)
- Onboarding de nuevos contributors friccionaba
- Code review tomaba horas por cambios chicos

### Root cause

**"Un archivo por plataforma" es tentador pero no escala.** SimulatorBridge era el catch-all de "cualquier cosa iOS" — un anti-pattern que crece sin feedback hasta que duele.

La "regla" tácita era: "si es iOS y no es genérico, va ahí". No había presión para splittear porque:
- Los tests existentes seguían pasando
- No había métricas de file-size que alertaran
- Refactoring "por belleza" se sentía low priority

### Qué aprendimos

> **LOC por archivo es una métrica de salud del codebase.** Cuando un archivo pasa de 800-1000 LOC sin justificación arquitectural, es señal de que están mezcladas responsabilidades.

### Fix aplicado (PR #110)

**Extension-based split** — 4 archivos, responsabilidades claras:

| Archivo | LOC | Rol |
|---------|-----|-----|
| `SimulatorBridge.swift` | 677 (de 1964) | gestures + input + state |
| `+AXEngine.swift` | 521 | AX queries |
| `+SimCtlEngine.swift` | 677 | simctl wrappers |
| `+MediaEngine.swift` | 200 | media + camera |

Cada uno es una **extension del mismo tipo** en archivo separado. Preserva la API pública exacta (cero impacto en callers) pero permite ownership clara por archivo.

### Preventivo para el futuro

- Límite mental de 800 LOC por archivo antes de considerar split
- Cada clase de utilidad grande debería tener **subdivisiones documentadas** (MARK: sections) que después puedan extraerse como extensions
- En reviews, flagear PRs que agregan >100 LOC a un archivo ya >500 LOC

---

## PM-006 — Binarios del editor stale tras `cargo clean`

**Período:** reportado abril 2026 · **Issue:** [#81](https://github.com/fsaldivar-dev/AutoPilot/issues/81) · **Fix:** PR #109

### Contexto

El editor Tauri spawnea `auto interactive` como sidecar. Tauri busca el binario en dos ubicaciones:
1. `editor/auto` (sibling del CLI) — dev mode
2. `editor/src-tauri/binaries/auto-<target-triple>` — production bundle

`cli/dev-install.sh --editor` copia los binarios a ambos. Pero al correr `cargo clean` en `editor/src-tauri`, los binarios de `target/debug/` (donde Tauri los vinculaba) se borran.

### Qué pasó

- Devs que workflow-eaban así hacían `cargo clean` → `cargo build` → `npm run tauri dev`
- Tauri spawneaba un **binario stale** (de días atrás) de las ubicaciones "permanentes"
- Sin notificación — solo errores confusos tipo "Unknown command: interactive"

### Root cause

El ciclo `cargo clean` afecta solo `target/`. Los binarios en `editor/auto` y `editor/src-tauri/binaries/` **siguen vivos** pero pueden estar desactualizados.

`refresh-binaries.sh` arreglaba esto manualmente, pero **el dev tenía que acordarse** — no había trigger automático.

### Qué aprendimos

> **Los "pasos manuales" son bugs latentes.** Cualquier cosa que requiera memoria del dev eventualmente va a fallar.

### Fix aplicado (PR #109)

En `editor/src-tauri/tauri.conf.json`:

```json
"beforeDevCommand": "./refresh-binaries.sh && npm run dev",
"beforeBuildCommand": "./refresh-binaries.sh --release && npm run build"
```

Cada `tauri dev|build` fuerza refresh de binarios desde `cli/.build/`. Si el CLI no está compilado, `refresh-binaries.sh` sale con `exit 1` — dev ve el error claro y corre `cli/dev-install.sh`.

### Preventivo transferible

Los "scripts manuales recordatorios" (README.md con "don't forget to run X") deben integrarse como pre-commit hooks, beforeDevCommand, o similar — no como documentación.

---

## Resumen de lecciones transversales

| Lección | Aplicada en |
|---------|-------------|
| No hay performance gratis en sistemas compartidos | PM-001 — event-driven → oversampling |
| Selector = propiedad predecible, no estado runtime | PM-002 — recorder |
| Apple cambia defaults sin avisar | PM-003 — Xcode 26 sim cloning |
| Simulator ≠ device — features del kernel difieren | PM-004 — DYLD_INSERT_LIBRARIES |
| LOC por archivo es métrica de salud | PM-005 — SimulatorBridge |
| Pasos manuales son bugs latentes | PM-006 — editor refresh |

Cada una de estas es bandera roja cuando aparece en un nuevo diseño. En code review, si alguien propone una solución que pisa una de estas minas, vale referir a su post-mortem.

---

## Ver también

- [docs/HISTORY.md](HISTORY.md) — timeline completo con contexto
- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — estado actual resultante
- [docs/ROADMAP.md](ROADMAP.md) — riesgos pendientes para próximas fases
