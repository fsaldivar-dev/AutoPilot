# Recorder Semantico — Bitacora de Desarrollo

## Sesion 2026-04-05

### Objetivo
Implementar `auto record output.auto` (iOS) y `auto-android record output.auto` (Android) — captura pasiva de interacciones del usuario con el Simulator/emulador, generando scripts `.auto` con selectores semanticos.

### Fase 1: RFC + Diseno (PR #45, previo)
- RFC completo en `docs/rfc/recorder-semantico.md` — analisis de fragilidad, comparativa con Maestro/Appium/Autonoma
- `ParsedCommand` — parsea `tap[button] "X" within "Y"`
- `TargetResolver` con scope + requiredRole
- `findAXElementScoped()` con fallback chain
- `inspect --context` — parent chain con marcadores

### Fase 2-4 iOS: CGEventTap recorder (PR #47)

**EventRecorder.swift** — CGEventTap `.listenOnly`
- Primer intento: filtro por PID del Simulator → no funciona, mouseUp no llega
- Fix: filtro por window frame del Simulator (coordenadas)
- Fix: resolver en mouseDown, no esperar mouseUp

**SemanticResolver.swift** — coordenada → selector
- Primer intento: `AXUIElementCopyElementAtPosition` → no funciona con Simulator
- Fix: hit-test manual recursivo del AX tree (como SimulatorBridge.findElementAt)
- Primer intento: tree post-click (stale) → cae a tapAt
- Fix: capturar tree en thread del event tap (sincrono, pre-click)
- Fix 2: `findSimulatorContentFast()` sin activate()

**ScriptGenerator.swift** — ResolvedAction → .auto
- Primer intento: `wait 0.5` por AX changes → no funciona (UIStabilizer reset)
- Fix: waitFor basado en gap de tiempo >1.5s
- Fix: waitFor en transicion tapAt → tap (indica cambio de pantalla)
- Fix: waitFor antes del primer tap (despues de launch)
- Fix: strip [N] de waitFor → revertido, ahora waitFor soporta [N]

**RecordingSession.swift** — orquestador
- Race condition: `flushPendingTap()` en stop() desde otro thread → segundo click perdido
- Fix: `resolveQueue.sync {}` en stop()
- Scroll: CGEventTap NO recibe scrollWheel del trackpad en Simulator
- Investigacion: los gestos del trackpad van directo al proceso del Simulator

**Coordinadas fallback** — `tap "308,515"` se parsea como multi-tap
- Fix: usar `tapAt 308 515` para fallback a coordenadas

**E2E iOS**: 50/50 corridas con script editado (1 swipe extra). 0/5 sin editar.

### Fase 5: Android recorder (PR #48)

**GetEventParser.swift** — `adb shell getevent -lt`
- Primer intento: busca `BTN_TOUCH DOWN` para detectar finger → no siempre llega
- Fix: usar `ABS_MT_TRACKING_ID >= 0` como touch down, `ffffffff` como touch up
- Bug: state machine emitia solo `up` — `hasEmittedDown` flag faltaba
- Calibracion: primer intento parseaba `0037` (tracking ID, max 15) como Y
- Fix: parseo estricto de `0035` y `0036` con `hasPrefix` + `contains("min")`

**AndroidSemanticResolver.swift** — JSON tree hit-test
- Hit-test: busca el mas profundo, pero si no tiene label, busca el mas cercano con label (radio 80px)
- Compose Button sin label: TextView tiene el texto, Button hermano tiene el click handler
- Fix: `findClickableFrame()` busca Button padre que contiene la posicion del TextView
- `within` generico: `android:id/content` es root de toda la app, inutil como scope
- Fix: `isGenericContainer()` filtra `android:id/*`, fuerza fallback a `[N]`

**AndroidRecordingSession.swift** — orquestador
- Auto-inject terminate+launch: primer intento usaba `AutoPilotConfig.get("bundle")` (config iOS)
- Fix: `detectForegroundApp()` via `dumpsys activity recents`
- Bug: `{dev.autopilot.test.Explorea}` con llaves → strip braces
- Tree legacy: 2s por dump → demasiado lento, taps caen a tapAt
- Fix: tree cache con refresh cada 1s + post-click refresh a 0.5s
- AgentBridge tree: 6ms → suficientemente rapido para captura en tiempo real

**waitFor + [N]** — `waitFor "Cerrar sesion[2]"` esperaba literal
- Fix: CommandDispatcher.waitFor parsea [N] y espera N+ matches
- Fix: `search()` con `try?` para retry en "No active window"

**tap en Android** — `bridge.tap()` usa `performAction(ACTION_CLICK)` que falla en TextViews no-clickable
- Fix: CLIAndroid tap resuelve en tree y usa `tapAtCoordinate` en centro del frame
- Fix: `findClickableFrame` busca el Button mas pequeno que contiene el punto

**E2E Android**: 3/3 corridas con script editado (2 ediciones). 0/5 sin editar.

### Limitaciones documentadas

| Limitacion | iOS | Android | Solucion futura |
|---|---|---|---|
| Scroll no detectable | Trackpad bypass CGEventTap | getevent detecta swipe pero no pixels | `scrollUntilVisible` con verificacion de viewport |
| scrollTo no verifica visibilidad | AX tree incluye offscreen | Igual | Verificar frame vs viewport |
| SwiftUI sheet toolbar buttons | No en AX tree | N/A | Limite de Apple |
| Compose Button sin label | N/A | TextView no clickable | findClickableFrame (implementado) |
| Keyboard (Android) | N/A | Virtual keyboard = touch events | Detectar region del teclado |

### Archivos creados/modificados

**iOS (PR #47):** 4 creados, 3 modificados — 1240 lineas
**Android (PR #48):** 5 creados, 4 modificados — 1201 lineas
**Total:** 9 archivos nuevos, 7 modificados, ~2400 lineas
