# AutoWait — auto-wait + verificación post-tap (#157)

Tolerancia a flakiness estilo Maestro en el nivel compartido (`AutoCore/AutoWait.swift`),
consumida por el dispatcher (`executeSharedCommand`) y los enhancements de tap de
iOS y Android. Es el fix de FONDO de la clase de bugs "reporta éxito sin efecto"
(las tres "mentiras en verde" de la auditoría 2026-07-03).

## Qué hace

1. **Pre-acción (estabilidad)** — antes de `tap`/`type`/`scroll`, poll del árbol de
   accesibilidad hasta obtener **2 lecturas consecutivas con el mismo hash**. Si la
   UI está animando, la acción espera a que termine. Best-effort: si el deadline
   vence con la UI aún cambiando, la acción procede igual (nunca bloquea).

2. **Post-tap (verificación de efecto)** — hash del árbol antes del tap; después
   del tap se pollea esperando que el hash **cambie**. Sin cambio →
   `[tap] warning: la UI no cambió tras el tap en 'X' …` en **stderr**.
   Con `AUTO_RETRY_TAP=1` además se hace UN re-tap estilo Maestro antes del warning.

3. **Reuso de árboles** — el árbol que `TapTargets` fetchea para decidir multi-tap
   por coma se hereda como primera muestra de estabilidad; el árbol estabilizado se
   reusa para la resolución del target (Compose clickable, `label[N]`, `$N`).
   Cero fetches duplicados en el camino feliz.

## El hash

FNV-1a 64-bit sobre `role + title + label + identifier + frame` recursivo
(`AutoWait.treeHash`). **`value` queda fuera deliberadamente**: los values flapean
sin que la pantalla "cambie" (relojes, contadores, texto mientras se tipea) y el
loop de estabilidad nunca convergería. La asimetría es la misma de
`ViewFingerprint`: dos hashes distintos prueban cambio; dos iguales no prueban
identidad total — exactamente lo que la verificación post-tap necesita.

## Tiempos y umbrales (finales, ajustables por env)

| Variable | Default | Qué controla |
|---|---|---|
| `AUTO_NO_WAIT=1` | off | Kill-switch total (benchmarks, CI rápido) |
| `AUTO_RETRY_TAP=1` | off | Re-tap estilo Maestro si el hash no cambió |
| `AUTO_WAIT_STABLE_MS` | 1500 | Deadline de estabilidad pre-acción |
| `AUTO_WAIT_POLL_MS` | 50 | Espaciado entre muestras (el sleep descuenta el costo del fetch) |
| `AUTO_WAIT_RETRY_MS` | 800 | Deadline de espera de cambio post-tap, por intento |
| `AUTO_WAIT_MAX_FETCH_MS` | 250 | Umbral de backoff por árbol caro |

**Backoff adaptativo ("mide y decide")**: se mide el costo de cada fetch de árbol.
Si excede `AUTO_WAIT_MAX_FETCH_MS`, AutoWait se apaga solo para el resto del
proceso — se paga a lo sumo UNA lectura cara. Con el agente Android (~25-45ms) y
el observer iOS el costo es casi gratis; en XCUI puro (árbol de segundos) el
backoff lo neutraliza sin configuración.

## Por qué el warning NO es error duro

Existen taps legítimos sin efecto visible: tap en un campo ya enfocado, toggles de
estado interno, taps que lanzan trabajo en background. Un error duro rompería
scripts válidos. El warning en stderr mata la mentira en verde sin fallar en falso.
Para postcondiciones duras siguen estando `waitFor`, `assertScreen` y `assertOCR`.

## Por qué el re-tap es OPT-IN (hallazgo de la verificación runtime)

Con re-tap por default, el keypad de PIN de Explorea (dots dibujados en Canvas)
demostró el fallo: el árbol de accesibilidad queda **byte-idéntico** tras tipear
un dígito (verificado con `tree` antes/después: diff vacío), el hash no cambia,
el re-tap dispara y el dígito se duplica → PIN "1223…" → `Código incorrecto` →
`scripts/examples/android-login.auto` roto. Es la misma razón por la que Maestro
terminó deprecando `retryTapIfNoChange`: el re-tap ciego convierte "efecto
invisible" en "efecto doble", que es peor que el problema que resuelve. Quien
sepa que su UI no tiene efectos hash-invisibles puede activarlo con
`AUTO_RETRY_TAP=1` (un solo re-tap, nunca más).

## Overhead medido (emulador Android, Explorea, tap real con navegación)

12 iteraciones por modo, `auto-android tap "Atardecer en Santorini"` (ms internos
del CLI, mismo binario, baseline = `AUTO_NO_WAIT=1`):

- ANTES: p50 ≈ **46ms** (38–82)
- DESPUÉS: p50 ≈ **158ms** (136–196)
- **Overhead ≈ 112ms p50** — bajo el objetivo de <150ms.

Costo en el peor caso honesto (tap hash-invisible, p.ej. dígito de PIN):
+`AUTO_WAIT_RETRY_MS` (800ms) + warning. Para scripts de PIN sensibles a tiempo,
`AUTO_NO_WAIT=1` restaura el comportamiento legacy exacto.

## Dónde está aplicado

- `cli/Sources/AutoCore/AutoWait.swift` — helper reutilizable (sync + async).
- `cli/Sources/AutoCore/CommandDispatcher.swift` — `tap` (completo), `type` y
  `scroll` (pre-estabilidad).
- `cli/Sources/AutoCore/AndroidTapEnhancement.swift` — todos los paths ($N,
  label[N], Compose, label plano), re-tap por el MISMO camino del tap original.
- `cli/Sources/AutoLibiOS/iOSTapEnhancement.swift` — path default (router →
  observer/XCUI). Los paths AX macOS legacy quedan fuera (motor opt-in de debug
  que tapea por referencia AXUIElement directa).

Tests: `cli/Tests/AutoWaitTests.swift` (26 tests: hash, estabilidad, bypass,
retry opt-in, backoff, integración dispatcher/enhancement con trees programados).
