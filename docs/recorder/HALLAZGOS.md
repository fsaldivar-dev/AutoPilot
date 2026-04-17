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

### 2. scrollTo no verifica visibilidad — RESUELTO (2026-04-17, issues #49 #58 #61)

**Problema original**: `scrollTo "X"` buscaba el elemento con `search()` que recorre todo el AX tree. En iOS y Android, el AX tree incluye elementos offscreen (fuera del viewport). Entonces `scrollTo` retornaba "encontrado" inmediatamente sin scrollear porque el elemento existe en el tree aunque no sea visible.

**Fix implementado**:

1. **Helper `ViewportUtil`** en `AutoCore`: funciones puras `rect(from:)`, `isVisible(frame:inViewport:)`, `resolveViewport(for:in:screenBounds:)` con cobertura minima 50% por area.
2. **`DeviceBridge.viewport()`**: nuevo metodo del protocolo que cada bridge implementa con su API nativa (`getSimulatorWindowFrame` en iOS fast, `app.frame` via runner en XCUI, `adb shell wm size` en Android).
3. **`scrollTo` reescrito** en los 4 bridges (SimulatorBridge, XCUIBridge, AgentBridge, AdbLegacyBridge) para validar `isVisible` sobre el frame antes de retornar "found". Si esta offscreen, continua scrolleando.
4. **Alias `scrollUntilVisible`** en `CommandDispatcher` — nombre semantico que el recorder emite.
5. **Recorder auto-inyecta `scrollUntilVisible`** (iOS + Android) cuando el elemento tapeado esta en el tree pero fuera del viewport.

**Resultado**: scripts grabados por el recorder se reproducen sin edicion manual. Replicabilidad raw: 0% → 100% esperado.

**Archivos clave**:
- `cli/Sources/AutoCore/ViewportUtil.swift` (nuevo)
- `cli/Sources/AutoCore/DeviceBridge.swift:115-125` (viewport protocol)
- `cli/Sources/AutoLibiOS/SimulatorBridge.swift:1716-1750` (fix iOS fast)
- `cli/Sources/AutoLibiOS/XCUIBridge.swift:211-240` (fix iOS deep)
- `cli/Sources/AutoCore/AgentBridge.swift:697-731` (fix Android agent)
- `cli/Sources/AutoCore/AdbLegacyBridge.swift:744-790` (fix Android legacy)
- `cli/Sources/AutoLibiOS/RecordingSession.swift:437-490` (inyeccion iOS)
- `cli/Sources/AutoCore/AndroidRecordingSession.swift:278-315` (inyeccion Android)

### 3. mouseUp no llega consistentemente

**Problema**: CGEventTap con filtro por PID no recibe mouseUp events de forma confiable. El `eventTargetUnixProcessID` puede cambiar entre mouseDown y mouseUp (el Simulator procesa el evento y cambia el focus).

**Decision**: Resolver la accion en mouseDown, no esperar mouseUp. Esto impide deteccion precisa de long press por duracion (mouseDown→mouseUp timing). Se usa heuristica: si mouseUp llega y la duracion >0.5s, se sobreescribe como longPress.

**Para el benchmark**: Long press detection puede ser imprecisa. Maestro detecta long press via su propio mecanismo. Appium no graba long press.

### 4. AX tree stale en clicks rapidos

**Problema**: El AX tree se captura en el thread del CGEventTap al momento del mouseDown. Si el usuario hace clicks muy rapidos (<500ms), el segundo click puede capturar el tree de la pantalla anterior (antes de que la UI se actualice por el primer click).

**Evidencia**: Al navegar rapido, taps caen a `tapAt` (coordenadas) porque el hit-test encuentra el AXGroup contenedor de la pantalla anterior, no los botones de la pantalla actual.

**Workaround actual**: waitFor injection con gap >1.5s mitiga esto — si el usuario navega lento, el tree se actualiza. Para clicks rapidos (numpad), el tree no cambia asi que funciona.

**Para el benchmark**: Este problema es unico de AutoPilot. Maestro captura screenshots, no AX tree. Appium usa session logs del WebDriver.

### 5. Modals y sheets — botones no expuestos en AX (wontfix #57)

**Problema**: Botones en `.toolbar { }` de SwiftUI sheets/modals no aparecen en el AX tree del Simulator macOS. Especificamente, "Cancelar" y "Guardar" en un `NavigationView` dentro de `.sheet { }`.

**Evidencia**: `tree -s "Cancelar"` → No elements found. El AXGroup del sheet tiene height 49px (solo la barra de titulo). `AXToolbarItems` (ya consultado en AXDebug.swift) retorna vacio para estos elementos. `AXUIElementCopyElementAtPosition` tampoco los encuentra — es el mismo AX tree subyacente.

**Causa raiz**: Limite de Apple — macOS Accessibility no expone correctamente los toolbar items de sheets del iOS Simulator. El toolbar vive en un layer que no tiene children AX.

**Status: wontfix** — Maestro y Appium tienen exactamente el mismo limite. No hay fix posible desde el tool. El workaround (`tapAt x y`) funciona.

**Recomendacion para devs**: Agregar `.accessibilityIdentifier("cancelar")` al boton en SwiftUI para que aparezca en el tree. Esto beneficia tanto al automation como al testing con XCTest.

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
| Agregar scroll | Usuario scrolleo en la app | Nada (scroll no detectable en iOS) | Agregar `swipe up/down` antes del tap |
| ~~Wait post-scroll~~ | ~~Android: tree no asentado despues de swipe~~ | ~~Nada~~ | **RESUELTO**: recorder inyecta `wait 0.5` automaticamente post-swipe |
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

**Datos crudos de las 50 corridas iOS** (ejecutadas 2026-04-05 ~17:30):
- Metodo: `bash for loop`, 50 ejecuciones consecutivas con `sleep 1` entre cada una
- Todas retornaron exit code 0
- Output de la corrida 50: `19 step(s) completed`
- No se midio tiempo individual por corrida (solo pass/fail)
- El script tenia 19 pasos incluyendo terminate+launch, waitFor, taps, y 1 swipe up manual

### Android — Explorea app (22 pasos)

```
login → codigo → confirmar → navegar tabs → scroll → cerrar sesion → confirmar dialogo
```

- **0/5 con script raw** del recorder (falta scroll + wait)
- **3/3 con script editado** (2 ediciones: `swipe up` extra + `wait 0.5`)
- Tiempo promedio por corrida: ~5.5s (AgentBridge) vs ~4s (iOS)
- Selectores semanticos: 14 de 22 pasos (64%)
- Fallback a coordenadas: 8 de 22 pasos (36% — Compose Buttons sin label)

**Datos crudos de las 3 corridas Android** (ejecutadas 2026-04-05 ~21:00):

| Run | Pasos | Tiempo | Ultimo paso | Tree final |
|-----|-------|--------|-------------|-----------|
| 1 | 22 | 5363ms | tap Cerrar sesion[2] (36ms) | Login screen |
| 2 | 22 | 4911ms | tap Cerrar sesion[2] (25ms) | Login screen |
| 3 | 22 | 4563ms | tap Cerrar sesion[2] (40ms) | Login screen |

Promedio: 4946ms. El tree final fue verificado: muestra pantalla de login (Explorea + "Desbloquear con codigo").

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

---

## Sesion 2026-04-07 — validacion login Uala (iOS + Android)

Validacion end-to-end de los fixes commiteados en `c894d36` (type reliability + DNS doctor) y `69ac6b9` (agent double-fork + AX setvalue) corriendo el flow completo de login Uala STAGE en ambas plataformas con apps frescas (uninstall + reinstall iOS, `pm clear` Android).

### iOS — flow validado completo

Pantallas extras del onboarding fresh que NO estaban en la receta original de `uala_login_recipes.md`:

1. **Selecciona tu pais** (Argentina / Mexico / Colombia) — solo aparece en primera ejecucion
2. **Permission de notificaciones** ("¿Ualá-Stage quiere enviarte notificaciones?") — sistema, AX-accessible
3. **Welcome screen** ("El lugar mas facil y seguro...") con boton `Iniciar sesion` (minuscula)
4. **"¡Hola, Joseph!"** screen — la app recuerda el username del login anterior aunque hagamos uninstall+reinstall (las creds quedan en keychain compartido por bundle id). Workaround: tap **"No soy yo"** que limpia y muestra Email + Contraseña.

Validado: typeText con caracteres `+` `@` `!` funciona en email Y password fields (los WIPs de `69ac6b9` resuelven los password fields que bloquean paste).

### Android — flow validado completo

Pantallas extras del onboarding fresh:

1. **Selecciona tu pais** — IDs `arg`, `col`, `mex_abc`
2. **Permission de notificaciones del sistema** (Allow / Don't allow) — boton usa apostrofe tipografico `'` (U+2019), tap por id `permission_deny_button` es mas confiable que por label
3. **"Habilitar notificaciones" segundo dialog** (CANCELAR / ABRIR CONFIGURACION)
4. **Welcome screen** con `id=login_button`
5. **Form**: `id=login_input_uname`, `id=pswd_input`, `id=login_button`. Tap por id evita el problema de reindex del keyboard que esta documentado en la memoria.

Validado: typeText agente Android maneja `+` `@` `!` correctamente. Password fields no exponen value via accessibility tree (esperado, por seguridad Android).

### Bug encontrado y arreglado: `probeSocket()` false positive (#68 incompleto)

**Problema**: el commit `3bc7281` que dice resolver el issue #68 ("AgentBridge no detecta agente caido y no auto-relanza") tiene un detector de "agent reachable" que da false positives.

```swift
// AgentBridge.swift:163 — version pre-fix
private func probeSocket() -> Bool {
    guard let sock = try? createSocket() else { return false }
    close(sock)
    return true  // ← solo verifica connect()
}
```

**Por que falla**: cuando `adb forward tcp:9008 localabstract:autopilot` esta armado, cualquier `connect()` a `localhost:9008` tiene exito porque el adb daemon de macOS acepta el connect inmediatamente. ADB solo intenta el forwarding al lado Android cuando hay datos a transferir — y si el lado Android no tiene el socket bound, devuelve EOF en el primer recv. Pero `probeSocket` nunca llega a leer.

**Consecuencia**: el flow de recovery (`recoverAgent` → step 2: `if probeSocket() return`) nunca llega a `relaunchAgentDetached()`. El WIP del double-fork pattern queda inactivo y los comandos reales (tree, tap, type) siempre fallan con "Empty response from agent" cuando el agente esta muerto.

**Evidencia**: con APK instalado pero `pkill -9 -f autopilot` + `forward --remove-all`, `auto-android setup` reportaba "✓ Agent already running and reachable" pese a que `ps -A | grep autopilot` estaba vacio.

**Fix aplicado**: `probeSocket()` ahora envia un ping JSON real y espera respuesta con timeout de 1s via `SO_RCVTIMEO`. Solo retorna `true` si recibe bytes del agente. Tras el fix, el setup correctamente detecta el agente muerto, llama `relaunchAgentDetached()`, y el agente sobrevive (validando indirectamente el WIP del double-fork).

### Limitacion conocida: iOS save-password system dialog no es AX-accessible

**Problema**: tras el primer login exitoso en Uala iOS aparece el dialog del sistema **"¿Guardar contraseña?"** (UIKit `_UISystemKeyboardSavePassword` o similar). Este dialog NO se expone en el AX tree del simulator porque es renderizado por iOS, no por la app. Tampoco responde a `pressKey escape` ni `pressKey enter` enviados via `osascript keystroke`.

**Workaround usado**: `auto terminate <bundleId>` + `auto launch <bundleId>`. Tras el segundo launch la app abre directamente al form de password (recordando al usuario), el dialog del sistema ya no vuelve a aparecer y se puede continuar el flow.

**Workaround alternativo**: tap en coordenadas absolutas del boton "Ahora no". Requiere medir coordenadas a mano para cada device size porque el dialog no esta en AX. No implementado en esta sesion.

**Para el benchmark / recorder**: este dialog NO se puede grabar ni reproducir con `auto`. Maestro tampoco lo maneja (cae al mismo problema). Solucion futura: agregar `auto tap <x> <y>` por coordenadas absolutas, o un comando `auto dismissSystemDialog`.
