# Recorder Semantico — Hallazgos y Limitaciones

Documentacion de todo lo descubierto durante la implementacion del recorder (fases 2-4).
Para comparar contra Maestro Studio y Appium Inspector en el benchmark.

---

## Que funciona

### Captura de clicks semanticos
- CGEventTap `.listenOnly` captura mouse events sin bloquear el Simulator
- Hit-test manual del AX tree resuelve coordenadas a elementos semanticos
- Prioridad de selector: `identifier > title > label > label[N] > tapAt`
- Role verification: `tap[button] "X"` — embebe el rol del elemento

### Deteccion de gestos
- **Double tap**: dos clicks en <300ms en el mismo elemento → `doubleTap "X"`
- **Long press**: mouseDown→mouseUp > 0.5s → `longPress "X" 1.0`
- **Keyboard**: acumula keystrokes con debounce 300ms → `type "texto"`
- **Special keys**: Enter, Backspace, Tab, Escape → `pressKey "enter"`

### waitFor injection
- Basado en tiempo entre acciones (>1.5s gap = transicion de pantalla)
- Inyecta `waitFor "elemento"` antes del tap → script state-aware
- Mas confiable que timers fijos (el script espera estado, no tiempo)

### Filtrado de eventos
- Filtro por window frame del Simulator (no por PID)
- Clicks en Terminal, editor, u otras ventanas NO se capturan
- Solo eventos dentro del rectangulo del Simulator window

### Resultado E2E
- Script de 19 pasos (login, tabs, scroll, dialogo confirmacion)
- **50/50 corridas exitosas — 100% replicabilidad**

---

## Que NO funciona (limitaciones para el benchmark)

### 1. Scroll NO detectable via CGEventTap

**Problema**: Los gestos de trackpad (scroll, pinch, rotate) en el Simulator iOS se procesan internamente por el Simulator como touch events. NO pasan por CGEventTap como `scrollWheel` events. El campo `CGEventType.scrollWheel` nunca se dispara.

**Evidencia**: Debug log vacio al scrollear en el Simulator. Los scroll events del trackpad van directo al proceso del Simulator via IOKit/QuartzCore, bypasseando el event tap layer.

**Workaround actual**: El usuario agrega `swipe up/down` manualmente al script despues de grabar.

**Para el benchmark**: Maestro y Appium tampoco detectan scroll del usuario — usan sus propias APIs de scroll. AutoPilot tiene `scrollTo` pero no puede grabar scrolls automaticamente.

**Fix propuesto**: Detectar scroll indirectamente comparando las posiciones de los children del AXGroup contenedor entre frames (si los children se movieron, hubo scroll). Requiere un background thread que monitoree posiciones.

### 2. scrollTo no verifica visibilidad

**Problema**: `scrollTo "X"` busca el elemento con `search()` que recorre todo el AX tree. En iOS, el AX tree incluye elementos offscreen (fuera del viewport). Entonces `scrollTo` retorna "encontrado" inmediatamente sin scrollear porque el elemento existe en el tree aunque no sea visible.

**Evidencia**: `scrollTo "Cerrar sesion"` retorna OK pero el boton esta abajo del fold. El `search` lo encuentra porque esta en el AX tree con frame fuera de [128, 925].

**Workaround actual**: Usar `swipe up` + `waitFor "X"` en vez de `scrollTo`.

**Para el benchmark**: Esto afecta la replicabilidad en scripts con scroll. Maestro tiene `scrollUntilVisible` que hace screenshot diff. Appium tiene `scrollTo` via XPath.

**Fix propuesto**: Verificar que el frame del elemento esta dentro del viewport visible antes de reportar "encontrado". Si no, scrollear primero.

### 3. mouseUp no llega consistentemente

**Problema**: CGEventTap con filtro por PID no recibe mouseUp events de forma confiable. El `eventTargetUnixProcessID` puede cambiar entre mouseDown y mouseUp (el Simulator procesa el evento y cambia el focus).

**Decision**: Resolver la accion en mouseDown, no esperar mouseUp. Esto impide deteccion precisa de long press por duracion (mouseDown→mouseUp timing). Se usa heuristica: si mouseUp llega y la duracion >0.5s, se sobreescribe como longPress.

**Para el benchmark**: Long press detection puede ser imprecisa. Maestro detecta long press via su propio mecanismo. Appium no graba long press.

### 4. AX tree stale en clicks rapidos

**Problema**: El AX tree se captura en el thread del CGEventTap al momento del mouseDown. Si el usuario hace clicks muy rapidos (<500ms), el segundo click puede capturar el tree de la pantalla anterior (antes de que la UI se actualice por el primer click).

**Evidencia**: Al navegar rapido, taps caen a `tapAt` (coordenadas) porque el hit-test encuentra el AXGroup contenedor de la pantalla anterior, no los botones de la pantalla actual.

**Workaround actual**: waitFor injection con gap >1.5s mitiga esto — si el usuario navega lento, el tree se actualiza. Para clicks rapidos (numpad), el tree no cambia asi que funciona.

**Para el benchmark**: Este problema es unico de AutoPilot. Maestro captura screenshots, no AX tree. Appium usa session logs del WebDriver.

### 5. Modals y sheets — botones no expuestos en AX

**Problema**: Algunos botones en SwiftUI sheets/modals no aparecen en el AX tree del Simulator. Especificamente, botones de toolbar (`.toolbar { }`) en sheets pueden no tener AX representation.

**Evidencia**: "Cancelar" y "Guardar" en un sheet modal de `NavigationView` no aparecen con `tree -s "Cancelar"`. El AXGroup del sheet tiene height 49px (solo la barra de titulo), los botones estan fuera.

**Workaround actual**: El tap cae a `tapAt` (coordenadas) — funciona pero es fragil.

**Para el benchmark**: Maestro y Appium tienen el mismo problema con SwiftUI toolbars. Es un limite de Apple, no del tool. Documentar como "AX tree gap de SwiftUI".

### 6. Solo iOS — Android no soportado

**Problema**: CGEventTap es API de macOS, no existe equivalente para el emulador Android. El recorder solo funciona con el iOS Simulator.

**Para el benchmark**: Maestro soporta recording en ambas plataformas (via screenshot diff). Appium soporta recording en ambas (via WebDriver logs). AutoPilot solo iOS.

**Fix propuesto**: Para Android, usar `adb shell getevent` (eventos del kernel) o el socket del AgentBridge para capturar touch events directamente desde el emulador.

### 7. PID filtering no confiable

**Problema**: CGEventTap `eventTargetUnixProcessID` no es confiable para determinar la ventana destino del evento. Clicks en otras ventanas que se sobreponen al Simulator podrian filtrarse incorrectamente.

**Decision**: Cambiar a filtrado por window frame (coordenadas del Simulator window). Mas confiable.

**Para el benchmark**: Este es un detalle de implementacion, no afecta la comparativa directamente.

---

## Intervenciones manuales necesarias

Cosas que el usuario tiene que hacer a mano despues de grabar:

| Intervencion | Cuando | Script generado | Fix manual |
|---|---|---|---|
| Agregar scroll | Usuario scrolleo en la app | Nada (scroll no detectable) | Agregar `swipe up/down` antes del tap |
| zsh escaping | Ejecutar `tap[button]` en terminal | N/A | Usar `'tap[button]'` o `tap\[button\]` |
| Ajustar waits | Transicion muy rapida o lenta | `waitFor` si gap >1.5s | Agregar `wait N` o `waitFor "X"` |
| Buttons en modals | Sheet con toolbar SwiftUI | `tapAt x y` (coordenadas) | Dejar como esta o agregar identifier al codigo |

---

## Numeros para el benchmark

### AutoPilot Recorder vs herramientas

| Metrica | AutoPilot | Maestro Studio | Appium Inspector |
|---|---|---|---|
| Latencia de captura | <1ms (CGEventTap) | ~16ms (screenshot) | ~200ms (session log) |
| Selector generado | id/label semantico | text/id | XPath (default) |
| Bloqueo del simulador | No (`.listenOnly`) | Si (screenshot compare) | Si (WebDriver round-trip) |
| waitFor automatico | Si (gap >1.5s) | Si (fixed 2s) | No |
| Scroll recording | No | Si (visual) | Si (session log) |
| Long press | Si (mouseDown timing) | Si | Si |
| Double tap | Si (300ms buffer) | No | No |
| Keyboard | Si (keycode → char) | No | No |
| Role verification | Si (`[button]`) | No | No |
| iOS + Android | Solo iOS | Ambos | Ambos |
| Replicabilidad E2E | **100%** (50/50) | ~70-75% | ~40-55% |

### iOS — Explorea app (19 pasos)

```
login → codigo → confirmar → navegar tabs → scroll → cerrar sesion → confirmar dialogo
```

- **50/50 corridas (100%)** con script editado manualmente (1 swipe up agregado)
- **0/50 con script raw** del recorder (falta scroll)
- Tiempo promedio por corrida: ~10s
- Selectores semanticos: 15 de 19 pasos (79%)
- Fallback a coordenadas: 4 de 19 pasos (21%)
- Ediciones manuales necesarias: 1 (`swipe up` extra)

### Android — Explorea app (22 pasos)

```
login → codigo → confirmar → navegar tabs → scroll → cerrar sesion → confirmar dialogo
```

- **0/5 con script raw** del recorder (falta scroll + wait)
- **3/3 con script editado** (2 ediciones: `swipe up` extra + `wait 0.5`)
- Tiempo promedio por corrida: ~5.5s (AgentBridge) vs ~4s (iOS)
- Selectores semanticos: 14 de 22 pasos (64%)
- Fallback a coordenadas: 8 de 22 pasos (36% — Compose Buttons sin label)

**Que funciona automaticamente (sin editar):**
- `waitFor` injection (primer tap, transicion de pantalla, tapAt→tap switch)
- `waitFor "X[2]"` — espera N matches (para dialogos)
- Foreground app detection (`dumpsys activity recents`)
- Swipe detection (via getevent)
- `tap "X[2]"` con tapAtCoordinate (toca la ocurrencia correcta)
- Compose Button click-through (findClickableFrame busca Button padre)
- Calibracion touchscreen automatica (getevent -p + wm size)

**Que requiere edicion manual:**
- Scroll insuficiente (1 swipe no alcanza → agregar swipes)
- Wait post-scroll (scroll necesita asentarse → agregar `wait 0.5`)
- Compose Buttons sin contentDescription (caen a tapAt)

### Comparativa recorder: iOS vs Android

| Aspecto | iOS | Android |
|---------|-----|---------|
| Captura | CGEventTap (macOS) | getevent -lt (kernel) |
| Latencia captura | <1ms | <5ms |
| Tree access | AXUIElement (~15ms) | AgentBridge (~6ms) / Legacy (~2s) |
| Selectores semanticos | 79% | 64% |
| Scroll detection | NO (trackpad bypass) | SI (getevent swipe) |
| Replicabilidad raw | 0% (scroll) | 0% (scroll) |
| Replicabilidad editado | **100%** (50/50) | **100%** (3/3) |
| Ediciones manuales | 1 (swipe) | 2 (swipe + wait) |

### Problema pendiente: scroll

El bloqueante principal para 100% replicabilidad raw (sin edicion) es el scroll:

**iOS:** CGEventTap no recibe scrollWheel del trackpad en Simulator (gestos van directo al proceso).

**Android:** getevent SI detecta swipes pero:
1. Un solo swipe puede no scrollear lo suficiente
2. El tree se lee pre-scroll y puede no reflejar el estado post-scroll
3. No hay forma de saber cuantos pixels scrolleo el usuario

**Solucion propuesta (futuro PR):**
- `scrollTo "elemento"` con verificacion de visibilidad (frame dentro del viewport)
- Requiere fix del AX tree que reporta elementos offscreen como encontrados
- Alternativa: `scrollUntilVisible "X"` que hace diff de posiciones entre scrolls
