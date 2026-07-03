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
| Tap | down→up <0.5s, desplazamiento <10px (#91) | touchDown+Up < 0.5s, movimiento < 20px |
| Long press | down→up >0.5s sin movimiento; emite `[secs]` si el hold supera 1s (#91) | touchDown→Up > 0.5s |
| Double tap | 2 clicks <300ms mismo selector | 2 taps <300ms mismo selector |
| Swipe | drag del mouse >=10px, rapido (>=500px/s), recto y axial → `scroll <elem> <dir>` o `swipe <dir>` (#91) | movimiento > 50px, calcula direccion |
| Drag | drag del mouse >=10px lento, diagonal o serpenteante → `drag <from> <to>` (#91) | NO |
| Scroll (rueda/trackpad 2 dedos) | scrollWheel con fallback a pointDelta (#50) | Solo swipe, no cantidad de pixels |

Los gestos directos de trackpad sobre el Simulator (pinch, pan multi-touch) siguen sin ser visibles — bypassean CGEventTap (ver Intento 6). Lo que #91 agrega es la clasificacion de los gestos que SI llegan: los drags del mouse, que antes se grababan como `tap` en el punto de origen.

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

## El problema del scroll — resuelto

El bloqueante historico para 100% replicabilidad raw era el scroll. En ambas plataformas:

1. iOS no puede detectar scroll del trackpad (bypasea CGEventTap)
2. Android detecta swipe pero no sabe cuantos pixels scrolleo el usuario
3. `scrollTo` tenia un bug: `search()` encuentra elementos offscreen, retorna sin scrollear

**Resuelto en 2026-04-17 (issues #49, #58, #61)** con tres piezas que se apoyan entre si:

1. **`ViewportUtil`** (helper compartido en `AutoCore`): dado un frame y un viewport, decide si el elemento esta visible con intersection >= 50%. Resuelve el viewport hibrido: busca un ancestro scrolleable (`AXScrollArea`, `ScrollView`, `RecyclerView`) en el tree, y si no lo encuentra cae a screen bounds.

2. **`scrollTo` arreglado** en los 4 bridges: ahora valida `isVisible` con el frame del elemento antes de considerarlo encontrado. `scrollUntilVisible` es alias para legibilidad.

3. **Recorder auto-inyecta `scrollUntilVisible`**: cuando el usuario tapea un elemento que esta en el tree pero fuera del viewport (porque scrolleo con trackpad o porque el hit-test resolvio un elemento offscreen), el recorder emite la linea de scroll antes del tap. El replay raw funciona sin edicion.

El viewport check fue posible gracias al segundo motor ([capitulo 15](15-el-segundo-motor.md)): el `XCUIBridge` expone `app.frame` via el runner, lo que en iOS fast ya teniamos con `getSimulatorWindowFrame()` pero en XCUI cerro la paridad.

---

## Lo que el recorder no puede ver: input sintetico (#132, #133)

En el triage de 2026-07-02 aparecieron dos issues gemelos: `auto record` en iOS
genero 0 lineas cuando los taps durante la sesion fueron `auto tap` desde otra
terminal (#132), y `auto-android record` reporto "3 lines" con solo 2 comandos
en el archivo y sin el tap de la sesion (#133).

**La parte esperada — ceguera al input sintetico.** Es arquitectura, no bug:

1. **iOS**: el recorder captura via `CGEventTap` en `.listenOnly` — solo ve
   eventos HID del host (mouse/teclado fisicos). `auto tap` usa
   `AXUIElementPerformAction(kAXPressAction)` (o XCUITest dentro del
   simulador), que entra directo al proceso del Simulator sin generar ningun
   CGEvent. El recorder no tiene donde verlo.
2. **Android**: el recorder captura via `adb shell getevent`, que lee
   `/dev/input` del kernel. `auto-android tap` (UiAutomation), igual que
   `adb shell input tap`, inyecta a nivel InputManager — nunca pasa por el
   kernel (ya lo habiamos verificado en el Intento 7).

En ambos casos el capturador esta *debajo* del punto de inyeccion. Grabar
input sintetico requeriria otro capturador (hook al bridge, no al hardware).
Desde ahora `record` imprime un aviso al arrancar en ambas plataformas:
los taps del propio CLI no se graban — usar interaccion real.

**La parte que si eran bugs.** Al revisar el pipeline por #132/#133 aparecieron
cuatro perdidas *reales* de interaccion, todas silenciosas:

1. **Filtro fail-closed del window frame (iOS)**: si `getSimulatorWindowFrame()`
   devolvia nil al arrancar, el frame quedaba en `.zero` y el guard
   `windowFrame != .zero && contains` descartaba TODOS los clicks humanos —
   0 lineas sin ningun error. Ahora es fail-open: frame desconocido = capturar
   todo, con warning en stderr. Y el frame se refresca cada 1s, porque mover
   la ventana del Simulator a mitad de grabacion dejaba el filtro apuntando
   al frame viejo.
2. **Race de drenaje en el stop (Android)**: `stop()` esperaba a que muriera
   el proceso adb (`waitUntilExit`) pero no a que el reader thread terminara
   de procesar los bytes ya escritos al pipe. El ultimo tap podia encolarse
   *despues* del flush y desaparecer. Ahora el reader señala EOF con un
   semaforo y `stop()` espera esa señal antes de flushear. La linea parcial
   final (getevent muere por SIGINT a mitad de linea) tambien se drena.
3. **Gestos descartados sin tree (Android)**: `handleTouchUp` exigia
   `touchDownTree != nil` — si el cache de tree estaba vacio (el `tree()`
   inicial fallo y el refresh de 1s no habia corrido), el gesto completo se
   tiraba en silencio, incluso swipes que ni usan el tree. Ahora los swipes
   se emiten siempre y tap/longPress caen a `tapAt x y` (fragil pero
   presente) en vez de perderse.
4. **El contador mentiroso**: "N line(s) recorded" usaba `lineCount`, que
   cuenta el buffer crudo — incluida la linea en blanco del header
   terminate/launch y los comments de fragilidad. De ahi el "3 lines" con
   2 comandos: terminate + launch + linea en blanco, y el tap nunca entro
   (era sintetico). Ahora se reporta `commandCount`: solo lineas ejecutables.

**Que aprendimos:** los cuatro bugs compartian el mismo patron — perdida
silenciosa. Un recorder puede perder eventos por razones legitimas, pero
nunca debe hacerlo sin dejar rastro: fail-open + warning es mejor que
fail-closed mudo, y un contador que miente es peor que no tener contador.

---

## Clasificacion de gestos por trayectoria (#91)

Hasta aqui el recorder trataba el mouse de forma binaria: duracion corta =
tap, duracion larga = longPress. Los `mouseDragged` entre down y up ni
siquiera se capturaban — un drag del usuario (reordenar una celda, ajustar
un slider, scrollear arrastrando) se grababa como `tap` en el punto de
origen. La intencion se perdia en silencio.

El fix tiene dos piezas:

1. **`EventRecorder` captura `leftMouseDragged`** y deja de filtrar
   dragged/up por window frame — un drag que arranca dentro de la ventana
   puede salirse a mitad de trayectoria, y filtrar el mouseUp dejaba el
   gesto abierto. Solo el mouseDown (inicio del gesto) exige estar dentro
   del frame, asi que clicks completos fuera de la ventana siguen sin
   generar lineas.

2. **`GestureClassifier`** (`cli/Sources/AutoLibiOS/GestureClassifier.swift`):
   funcion PURA — secuencia de puntos+timestamps → gesto — separada del
   CGEventTap y testeable con trayectorias sinteticas (21 tests en
   `cli/Tests/GestureClassifierTests.swift`). Las reglas, en orden:

```
desplazamiento neto < 10px:
    duracion >= 0.5s              → longPress (emite [secs] si hold > 1s)
    si no                          → tap (temblor de click ignorado)
desplazamiento >= 10px:
    velocidad >= 500px/s
      Y eje dominante >= 2x el otro
      Y camino <= 1.4x el neto     → swipe up/down/left/right
    cualquier otro movimiento      → drag(from, to)
```

Los umbrales estan en `GestureClassifier.Thresholds` (inyectables en tests).
500px/s en coordenadas de ventana ≈ el flick inercial de >800pt/s que
sugiere el issue #91, porque la ventana del Simulator renderiza a ~40-60%
del tamaño fisico del device.

`RecordingSession` decide en el mouseUp con la trayectoria completa:

- **tap** → pipeline existente (resolucion semantica contra el tree
  PRE-click, buffer de 300ms para double tap)
- **longPress** → mismo hit-test semantico, con duracion real si supera 1s
- **swipe** → si el punto de origen resuelve a un contenedor scrolleable o
  etiquetado, `scroll "<elem>" <dir>`; si no, `swipe <dir>` — mas `wait 0.5`
  post-scroll (#63)
- **drag** → ambos extremos por hit-test AX contra el tree PRE-gesto (el
  origen todavia esta en su lugar y el destino es lo que habia bajo el punto
  de drop). Si algun extremo no resuelve — o ambos resuelven al mismo
  elemento, como un slider que viaja con el puntero — cae a
  `drag x1,y1 x2,y2` con comment de fragilidad.

Lo que queda del issue #91 para iteraciones futuras: la cascada XCUI
(snapshot diff pre/post gesto para ambiguedades, consolidacion `scrollTo`,
deteccion de navegacion/sheet). Esta pieza cubre el paso 1 de la cascada —
features del gesto fisico — con el hit-test AX rapido que ya existia.

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
