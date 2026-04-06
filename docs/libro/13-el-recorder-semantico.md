# Capitulo 13 — El Recorder Semantico

## 8 intentos, 5 fracasos

Los recorders de automatizacion graban DONDE ocurrio la accion, no QUE fue accionado. Appium genera `/XCUIElementTypeButton[2]`. Maestro genera `tapOn: text: "Login"`. Ambos son fragiles — el primero rompe si agregan un boton, el segundo rompe si cambian el texto.

Decidimos construir un recorder que genere selectores semanticos. Un script que diga `tap "Confirmar"` en vez de `tapAt 375 812`. Que sepa esperar estados con `waitFor` en vez de `sleep 2000`. Que funcione en iOS y Android con el mismo formato.

Nos tomo 8 intentos. 5 fracasaron.

> **Nota:** El diario de laboratorio completo (crudo, cronologico, con cada debug log) esta en [recorder/BITACORA.md](../recorder/BITACORA.md). Este capitulo es la version narrativa.

---

## Intento 1: CGEventTap con filtro por PID

**Hipotesis:** macOS tiene `CGEvent.tapCreate` con modo `.listenOnly` — puede observar todos los eventos de mouse sin bloquearlos. Si filtramos por `eventTargetUnixProcessID` del Simulator, solo capturamos clicks en la ventana correcta.

**Que funciono:** El CGEventTap captura mouseDown correctamente en un thread dedicado con su propio CFRunLoop. La captura toma <1ms. El usuario interactua normalmente — nunca nota que esta grabando.

```swift
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,      // ← clave: no bloquea
    eventsOfInterest: eventMask,
    callback: eventCallback,
    userInfo: refcon
)
```

**Por que fallo:** Solo capturo 1 de 2 clicks. El debug revelo que mouseUp no llegaba:

```
[event] mouseDown at (182,249)
[event] mouseDown at (266,249)
```

Dos mouseDown, cero mouseUp. El `eventTargetUnixProcessID` cambia entre mouseDown y mouseUp — el Simulator procesa el primer evento y puede cambiar el focus, haciendo que el mouseUp tenga un PID diferente.

**Que aprendimos:** `eventTargetUnixProcessID` no es confiable entre eventos pareados. No podemos depender de mouseUp para detectar duracion (long press). La resolucion debe hacerse en mouseDown.

---

## Intento 2: AXUIElementCopyElementAtPosition

**Hipotesis:** Apple tiene `AXUIElementCopyElementAtPosition` que resuelve una coordenada de pantalla a un elemento AX directamente. Si la usamos con la coordenada del click, obtenemos el elemento sin recorrer el arbol.

**Por que fallo:** La funcion retorna `AXGroup` (el contenedor) en vez del boton. El Simulator es una ventana especial — sus elementos internos no responden bien a hit-test posicional de la API nativa:

```
[resolve] found element: role=AXGroup title=nil label=nil id=nil
```

El AXGroup no tiene label, titulo, ni identifier. Es inutil como selector.

**Que aprendimos:** Necesitamos un hit-test manual que recorra el arbol recursivamente, como ya hace `SimulatorBridge.findElementAt()`. La API nativa no funciona para el Simulator.

---

## Intento 3: Tree post-click (AX tree stale)

**Hipotesis:** Capturar el AX tree despues del mouseDown para resolver el elemento.

**Que hicimos:** `findSimulatorContent()` en el `resolveQueue` (async, despues del click).

**Por que fallo:** `findSimulatorContent()` llama `simRunning.activate()` que trae el Simulator al frente. Para cuando leemos el tree, el click ya proceso y la UI cambio. El primer click abrio Fitness.app, y el tree mostraba el permiso de ubicacion de Maps:

```
[hittest] depth=1 children=5
  AXStaticText "¿Permitir a Mapas utilizar tu ubicación?" pos=(190,392)
  AXButton "Permitir una vez" pos=(177,546)
  AXButton "No permitir" pos=(177,648)
```

El usuario habia hecho click en "Fitness" del home screen, pero el tree ya mostraba la app abierta con un dialogo de permisos.

**Que aprendimos:** El tree DEBE capturarse ANTES de que el click llegue al Simulator. La solucion: capturar en el thread del CGEventTap (sincrono, en el momento del evento) y pasar el tree al `resolveQueue` para la resolucion.

Tambien creamos `findSimulatorContentFast()` — version sin `activate()` para que la captura no robe el foco.

---

## Intento 4: Filtro por window frame (funciona)

**Que cambiamos:** En vez de filtrar por PID, obtener el frame de la ventana del Simulator via `getSimulatorWindowFrame()` y verificar que la coordenada del click esta dentro:

```swift
guard windowFrame.contains(location) else { return }
```

**Resultado:** Clicks en Terminal, editor, o cualquier otra ventana ya no se capturan. Ambos clicks se resuelven correctamente:

```
[REC]  tap "Configuración"
[REC]  tap "com.apple.settings.homeScreen"
```

El primer tap resolvio por identifier `Configuración`, el segundo por `com.apple.settings.homeScreen`. Ningun `tapAt`.

**Que aprendimos:** Las coordenadas del window frame son la forma mas confiable de filtrar — no dependen del PID que puede cambiar entre eventos.

---

## Intento 5: Fallback a coordenadas rompe el parser

**Hipotesis:** Cuando el hit-test no encuentra un elemento con label, caer a coordenadas como fallback.

**Que generamos:** `tap "308,515"`.

**Por que fallo:** El tokenizer parsea la coma como separador de multi-tap (`tap a,b,c`). Al hacer replay:

```
FAIL at line 8: Element not found: '308'
```

Busca un elemento llamado "308", no toca la coordenada.

**Fix:** Cambiar el fallback de `tap "x,y"` a `tapAt x y` — comando separado que el dispatcher ya maneja.

**Que aprendimos:** El formato del script importa. Un selector que parece texto pero es coordenada causa ambiguedad. Los comandos deben ser explicitos: `tap` es semantico, `tapAt` es coordenada.

---

## Intento 6: Scroll del trackpad

**Hipotesis:** CGEventTap captura `scrollWheel` events cuando el usuario scrollea en el Simulator con el trackpad.

**Que hicimos:** Agregamos handler para `.scrollWheel` con acumulador de deltas y debounce de 200ms. Debug log habilitado para ver los eventos.

**Evidencia:** El debug log estuvo **completamente vacio** al scrollear:

```
fsaldivar@MacBook-Pro % cat /tmp/scroll-debug.txt
fsaldivar@MacBook-Pro %
```

Cero eventos. Ni un solo scrollWheel.

**Por que fallo:** Los gestos del trackpad en el Simulator se procesan internamente como touch events de iOS. Van directo al proceso del Simulator via IOKit/QuartzCore, bypasseando completamente la capa de CGEventTap. No son scroll events de macOS — son gestos multi-touch que el Simulator traduce internamente.

**Que aprendimos:** El scroll es el ultimo problema del recorder. No hay solucion con CGEventTap para el Simulator. El usuario debe agregar `swipe up/down` manualmente post-grabacion. Esto es el unico bloqueante para 100% replicabilidad raw.

---

## Intento 7: Android — calibracion del touchscreen

**Hipotesis:** `adb shell getevent -lt` captura eventos raw del kernel. Los valores de `ABS_MT_POSITION_X/Y` se transforman a coordenadas de pantalla usando rangos de `getevent -p`.

**Que funciono:** getevent captura toques reales del emulador (no `adb input tap`, que inyecta a otro nivel):

```
[  405.510326] /dev/input/event1: EV_ABS  ABS_MT_POSITION_X    0000591f
[  405.510326] /dev/input/event1: EV_ABS  ABS_MT_POSITION_Y    00001428
```

**Por que fallo:** La calibracion Y siempre daba 2400 (el maximo de la pantalla). Debug:

```
[calibration] X: 0-32767 Y: 0-15 screen: 1080x2400
```

Y: 0-15 es el rango de `0037` (ABS_MT_TRACKING_ID, max 15 slots), no de `0036` (ABS_MT_POSITION_Y, max 32767). El parser confundia los codigos hex porque buscaba `contains("0036")` que tambien matcheaba en lineas que contenian `0036` como subcadena.

**Fix:** Parseo estricto con `trimmed.hasPrefix("0036")` y `trimmed.contains("min")`:

```
[calibration] X: 0-32767 Y: 0-32767 screen: 1080x2400
```

Ahora rawY=4792 se transforma a y=351 (arriba de la pantalla) correctamente.

**Que aprendimos:** Los codigos hex de `getevent -p` estan en la misma linea que los valores — no en la siguiente. Y codigos como `0035`, `0036`, `0037` son consecutivos; un `contains` loose matchea el equivocado.

---

## Intento 8: Compose Button sin label

**Hipotesis:** `tap "Cerrar sesion"` toca el elemento con ese texto en Android.

**Que hicimos:** El tree del dialogo en Jetpack Compose muestra:

```
View  [613,1344 284x126]
  TextView  "Cerrar sesion"  [645,1380 220x53]    ← tiene texto
  Button  [613,1354 284x105]                       ← clickable, sin label
```

El `tap "Cerrar sesion"` encuentra el `TextView` y envia `performAction(ACTION_CLICK)`. Pero el TextView no es clickable — el click handler esta en el `Button` hermano que no tiene `contentDescription`.

**Evidencia:** `tap "Cerrar sesion"` ejecuta sin error pero el dialogo no se abre. `tapAt 755 1407` (centro del Button) si lo abre.

**Fix:** `findClickableFrame()` recorre el tree buscando el `Button` mas pequeno que contiene la posicion del `TextView`. Si lo encuentra, usa las coordenadas del Button:

```swift
func findSmallestButton(x: Int, y: Int, in elements: [[String: Any]],
                         bestFrame: inout [String: Any]?, bestArea: inout Int) {
    for element in elements {
        let role = (element["role"] as? String) ?? ""
        let clickable = (element["clickable"] as? Bool) ?? false
        if (role == "Button" || clickable) && frame.contains(point) && area < bestArea {
            bestFrame = frame
        }
    }
}
```

**Que aprendimos:** En Compose, la separacion entre "que se muestra" (TextView) y "que se toca" (Button) es comun. El AX tree refleja la estructura de Compose, no la intencion del usuario. Para tap confiable en Android, siempre resolver a coordenadas del frame, no usar `performAction`.

---

## Lo que funciona hoy

Despues de los 8 intentos, el recorder genera scripts semanticos en ambas plataformas.

### Selectores: la cascada de prioridad

```
1. identifier   — "loginBtn"           — inmune a cambios visuales
2. title        — "Iniciar sesion"     — estable si el texto no cambia
3. label        — "Login button"       — description de accesibilidad
4. label[N]     — "Confirmar[2]"       — segundo match, fragil
5. tapAt x y    — tapAt 540 1200       — ultimo recurso, coordenadas
```

El recorder marca los selectores fragiles:

```auto
# no accessibilityIdentifier — selector may be fragile
tap "4"
```

Y desambigua con tres estrategias:
1. **Role filter**: `tap[button] "Submit"` — solo toca AXButton, no AXStaticText
2. **Within scope**: `tap "Camera" within "Toolbar"` — subtree del padre
3. **Occurrence**: `tap "Cerrar sesion[2]"` — segundo match

### waitFor: scripts state-aware

El recorder inyecta `waitFor` automaticamente en tres casos:

1. **Despues del launch** — el primer tap siempre espera
2. **Gap de tiempo >1.5s** — transicion de pantalla
3. **Transicion tapAt → tap** — la pantalla cambio

```auto
waitFor "Desbloquear con codigo"
tap "Desbloquear con codigo"
tap "1"
tap "2"
tap "3"
tap "4"
tapAt 438 2063
waitFor "Capturar"                     # ← transicion tapAt → tap
tap "Capturar"
waitFor "Mapa"                         # ← gap de tiempo
tap "Mapa"
```

`waitFor` con `[N]` espera a que haya N matches — resuelve dialogos de confirmacion:

```auto
tap "Cerrar sesion"                    # abre el dialogo
waitFor "Cerrar sesion[2]"             # espera que el dialogo aparezca (2 matches)
tap "Cerrar sesion[2]"                 # toca el boton del dialogo
```

### Deteccion de gestos

| Gesto | iOS | Android |
|-------|-----|---------|
| Tap | mouseDown < 0.5s | touchDown+Up < 0.5s, movimiento < 20px |
| Long press | mouseDown→Up > 0.5s | touchDown→Up > 0.5s |
| Double tap | 2 clicks <300ms mismo selector | 2 taps <300ms mismo selector |
| Swipe | NO detectable (trackpad bypass) | movimiento > 50px, calcula direccion |
| Scroll | NO detectable | Solo swipe, no cantidad de pixels |

---

## Resultados: Explorea app

Flujo completo: login con codigo → navegar 3 tabs → scroll → cerrar sesion → confirmar dialogo.

### Script sin editar (raw)

```
iOS:     0/5 — falla en scroll (un swipe no alcanza para "Cerrar sesion")
Android: 0/5 — falla en scroll + wait post-scroll
```

### Script con ediciones manuales

```
iOS:     50/50 (100%) — 1 edicion: agregar swipe up extra
Android:  3/3 (100%) — 2 ediciones: swipe up extra + wait 0.5 post-scroll
```

### Tiempos de replay

| Plataforma | Pasos | Tiempo promedio | Selectores semanticos |
|------------|-------|-----------------|----------------------|
| iOS | 19 | ~10s | 79% (15/19) |
| Android (AgentBridge) | 22 | ~5.5s | 64% (14/22) |
| Android (Legacy) | 22 | ~40s+ | <50% (tree tarda 2s) |

### Ediciones manuales necesarias

| Edicion | Por que | Plataformas |
|---------|---------|-------------|
| `swipe up` extra | Un swipe no scrollea suficiente | iOS + Android |
| `wait 0.5` post-scroll | El tree necesita tiempo para reflejar el scroll | Solo Android |

---

## El problema pendiente: scroll

El bloqueante para 100% replicabilidad raw es el scroll. En ambas plataformas:

1. iOS no puede detectar scroll del trackpad (bypasea CGEventTap)
2. Android detecta swipe pero no sabe cuantos pixels scrolleo el usuario
3. `scrollTo` tiene un bug: `search()` encuentra elementos offscreen, retorna sin scrollear

La solucion propuesta es `scrollUntilVisible` (issue #58) que verifica el frame del elemento contra el viewport antes de reportar "encontrado".

---

## Comparativa con la industria

| Aspecto | AutoPilot | Maestro Studio | Appium Inspector |
|---------|-----------|---------------|-----------------|
| Selector default | id/label semantico | text/id | XPath posicional |
| Latencia captura | <1ms iOS, <5ms Android | ~16ms (screenshot) | ~200ms (session log) |
| Bloqueo del device | No (`.listenOnly`/getevent) | Si (screenshot compare) | Si (WebDriver round-trip) |
| waitFor automatico | Si (3 triggers + `[N]`) | Si (2s fijo) | No |
| Scroll recording | No (iOS), parcial (Android) | Si (visual) | Si (session log) |
| Role verification | Si (`[button]`) | No | No |
| Keyboard recording | Si (iOS) | No | No |
| Replicabilidad (editado) | **100%** (50/50 iOS, 3/3 Android) | ~70-75% | ~40-55% |

El 100% de AutoPilot requiere 1-2 ediciones manuales. El 70-75% de Maestro es sin edicion pero con `waitForAnimationToEnd` de 2s que agrega 40s+ a un script de 20 taps. Las replicabilidades de Maestro y Appium son estimaciones basadas en issues documentados — las de AutoPilot son mediciones reales.

---

Siguiente: el benchmark de recorders (issue #62) medira estas herramientas con el mismo flujo, en el mismo dispositivo, con datos reales.
