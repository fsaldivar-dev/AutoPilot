# Recorder Semantico — Bitacora de Desarrollo

## Sesion 2026-04-05 (16:00 — 23:00)

### Objetivo
Implementar `auto record output.auto` (iOS) y `auto-android record output.auto` (Android) — captura pasiva de interacciones del usuario, generando scripts `.auto` con selectores semanticos.

---

### 16:00 — Diseño e implementación base (iOS)

**Plan:** CGEventTap `.listenOnly` en thread dedicado, SemanticResolver con AX hit-test, ScriptGenerator para formatear .auto.

Creamos 4 archivos: EventRecorder.swift, SemanticResolver.swift, ScriptGenerator.swift, RecordingSession.swift. Compilacion exitosa al primer intento. `auto record` sin argumentos imprime usage correctamente.

### 16:30 — Primer record + replay: solo 1 de 2 clicks

```
./auto record /tmp/test.auto    # click Fitness, click Safari, Ctrl+C
```

Resultado: solo el primer click en el script. Debug:

```
[event] mouseDown at (182,249)
[event] mouseDown at (266,249)
```

Ambos mouseDown llegan pero solo el primero se emite. **Causa:** race condition en `flushPendingTap()` — el `stop()` se ejecuta en el main thread via SIGINT, pero `pendingTap` se establece en `resolveQueue`. El segundo click esta pendiente cuando `stop()` lo flushea.

**Fix:** `resolveQueue.sync { flushPendingTap() }` en `stop()`.

### 16:40 — Hit-test no resuelve: cae a coordenadas

Con ambos clicks capturados, el script genera `tapAt 182,249` en vez de `tap "Fitness"`.

Debug:
```
[hittest] depth=0 children=11
[hittest] depth=0 HIT AXGroup frame=[126,128 366x797]
[hittest] depth=1 children=8
```

El AXGroup se encuentra pero sus 8 children no matchean el punto. **Causa:** `AXUIElementCopyElementAtPosition` no funciona con el Simulator. Reemplazamos por hit-test manual recursivo (como `SimulatorBridge.findElementAt`).

### 16:50 — AX tree stale: muestra la pantalla anterior

Con el hit-test manual, el debug muestra que los children del AXGroup son un dialogo de Maps (permiso de ubicacion) — no los iconos del home screen:

```
[hittest] d=1 AXStaticText "¿Permitir a Mapas utilizar tu ubicación?" pos=(190,392)
[hittest] d=1 AXButton "Permitir una vez" pos=(177,546)
```

**Causa:** `findSimulatorContent()` llama `activate()` y captura el tree DESPUES del click. Para ese momento, el click ya abrio la app y la UI cambio.

**Fix:** Capturar el tree en el thread del CGEventTap (sincrono, pre-click) y pasar como parametro al `resolveQueue`. Creamos `findSimulatorContentFast()` sin `activate()`.

### 17:00 — Primer tap semantico exitoso

```
[REC]  tap "Configuración"
[REC]  tap "com.apple.settings.homeScreen"
```

Ambos clicks resuelven semanticamente. El primero usa `label=Configuración`, el segundo usa `identifier=com.apple.settings.homeScreen`.

### 17:05 — Clicks en Terminal se capturan

El filtro por PID no funciona — clicks en la ventana de Terminal aparecen como taps en el script. **Causa:** `eventTargetUnixProcessID` no es confiable.

**Fix:** Filtrar por window frame del Simulator: `windowFrame.contains(location)`.

### 17:10 — Fallback a coordenadas rompe el parser

`tap "308,515"` falla en replay:
```
FAIL at line 8: Element not found: '308'
```

El tokenizer parsea la coma como separador de multi-tap. **Fix:** usar `tapAt 308 515` para coordenadas.

### 17:22 — E2E iOS: 50/50

```bash
./auto record Explorea.auto    # login, tabs, scroll, cerrar sesion
./auto run Explorea.auto       # replay
```

Script de 19 pasos. Con 1 edicion manual (`swipe up` extra), 50/50 corridas exitosas. 100% replicabilidad.

### 17:30 — Scroll no detectable

Agregamos handler para `scrollWheel` con debug log. Al scrollear en el Simulator:

```
fsaldivar@MacBook-Pro % cat /tmp/scroll-debug.txt
fsaldivar@MacBook-Pro %
```

Cero eventos. Los gestos del trackpad van directo al proceso del Simulator via IOKit, bypasseando CGEventTap.

**Decision:** Documentar como limitacion. El usuario agrega `swipe up/down` manualmente.

---

### 19:00 — Inicio del recorder Android

**Plan:** `adb shell getevent -lt` para captura de eventos kernel. Mover `ResolvedAction` y `ScriptGenerator` a AutoCore (compartido).

### 19:20 — getevent funciona

El usuario confirma que tocar el emulador genera output:
```
[  405.510326] /dev/input/event1: EV_ABS  ABS_MT_POSITION_X    0000591f
[  405.510326] /dev/input/event1: EV_ABS  ABS_MT_POSITION_Y    00001428
```

### 19:40 — Primer record Android: 0 taps

Con `--legacy` (adb bridge), el recorder arranca pero no captura taps. **Causa:** el tree legacy toma ~2s por `uiautomator dump`. Para cuando el tree se lee, la UI ya cambio. Todos los taps caen a `tapAt`.

### 19:50 — Calibracion Y: todo en 2400

```
[calibration] X: 0-32767 Y: 0-15 screen: 1080x2400
```

Y: 0-15 es el rango de `0037` (tracking ID slots), no `0036` (position Y).

**Causa:** `contains("0036")` matchea en lineas que contienen "0036" como subcadena. El parser confunde codigos hex consecutivos.

**Fix:** `trimmed.hasPrefix("0036")` + `trimmed.contains("min")`.

### 20:00 — App equivocada en el script

El script generado dice `terminate "dev.autopilot.test.CameraTestApp"` pero el usuario grabo con Explorea. **Causa:** `AutoPilotConfig.get("bundle")` usa el config de iOS, no la app actual de Android.

**Fix:** `detectForegroundApp()` via `adb shell dumpsys activity recents`. Bug adicional: el package viene con llaves `{dev.autopilot.test.Explorea}` → strip braces.

### 20:08 — AgentBridge: primer tap semantico Android

Sin `--legacy`, usando el AgentBridge (6ms por tree):

```
[REC]  tap "Camera1"
```

Primer selector semantico en Android.

### 20:22 — Compose Button sin label

`tap "Cerrar sesion"` en el dialogo de confirmacion no abre nada. El tree muestra:

```
View  [613,1344 284x126]
  TextView  "Cerrar sesion"  [645,1380 220x53]
  Button  [613,1354 284x105]
```

El `performAction(ACTION_CLICK)` en el TextView no hace nada. El Button no tiene label.

**Fix:** `findClickableFrame()` busca el Button mas pequeno que contiene la posicion del TextView.

### 20:47 — waitFor "Cerrar sesion[2]" falla

El `waitFor` buscaba el string literal "Cerrar sesion[2]" en el tree.

**Fix:** `CommandDispatcher.waitFor` ahora parsea `[N]` con `TargetResolverShared.parse()` y espera a que haya N+ matches.

### 21:10 — E2E Android: 3/3

Script de 22 pasos. Con 2 ediciones manuales (swipe up + wait 0.5), 3/3 corridas exitosas.

### 21:30 — Script raw: 0/5 (ambas plataformas)

Sin ediciones, el script falla en el paso del scroll. Es el mismo problema en iOS y Android.

---

### Preguntas del usuario que guiaron el debug

Cada una de estas preguntas disparo una investigacion y un fix:

| Pregunta | Descubrimiento |
|----------|---------------|
| "no escroleea" | CGEventTap no recibe scrollWheel del trackpad |
| "legacy, ya no lo usamos" | Cambiar a AgentBridge (6ms vs 2s) |
| "puedes resolverlo sin coordenadas?" | `tap "Cerrar sesion[2]"` con occurrence |
| "no termino, debio cerrar sesion" | `performAction(ACTION_CLICK)` falla en TextViews de Compose |
| "levanto una app que no probe" | `detectForegroundApp()` en vez de config iOS |
| "correlo 3 veces" y "no validaste los arboles" | Verificar tree final, encontrar flakiness del swipe |

---

### Archivos creados/modificados

**iOS (PR #47):** 4 creados, 3 modificados — 1240 lineas
**Android (PR #48):** 5 creados, 4 modificados — 1201 lineas
**Total:** 9 archivos nuevos, 7 modificados, ~2400 lineas
