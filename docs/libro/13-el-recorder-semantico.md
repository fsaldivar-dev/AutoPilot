# 13. El Recorder Semantico

> "Un test que a veces pasa y a veces falla no es un test — es una loteria."
> — Martin Fowler, *Eradicating Non-Determinism in Tests*

---

## El problema que resuelve

Los recorders de automatizacion graban DONDE ocurrio la accion, no QUE fue accionado. El resultado son scripts fragiles que rompen con cualquier cambio de layout.

```
# Appium Inspector genera esto:
/XCUIElementTypeApplication/XCUIElementTypeWindow/XCUIElementTypeButton[2]

# AutoPilot genera esto:
tap "Confirmar"
```

La diferencia es fundamental: XPath describe posicion, el label describe identidad. Si el desarrollador agrega un boton antes en el layout, el XPath rompe silenciosamente. El label sigue funcionando.

## Dos mecanismos, una misma salida

El recorder tiene dos implementaciones completamente diferentes — una por plataforma — pero ambas producen el mismo formato `.auto`.

### iOS: CGEventTap

macOS expone `CGEvent.tapCreate` con modo `.listenOnly` que permite observar TODOS los eventos de mouse/teclado del sistema sin bloquearlos ni modificarlos. El Simulator es una ventana macOS normal.

```
Usuario toca Simulator
    |
CGEventTap (.listenOnly)     — captura coordenada, no bloquea
    |
AX tree hit-test             — busca el elemento mas profundo en esa coordenada
    |
Selector semantico           — identifier > title > label > label[N] > tapAt
    |
Script .auto                 — tap "Confirmar"
```

El CGEventTap corre en un thread dedicado con su propio CFRunLoop, separado del main thread donde vive el UIStabilizer. La captura toma <1ms — el usuario nunca nota que esta grabando.

El AX tree se captura en el thread del event tap (sincrono, ANTES de que el click llegue al Simulator) y se pasa al `resolveQueue` para la resolucion semantica. Esto es critico: si capturas el tree DESPUES del click, la UI ya cambio.

### Android: getevent

Android no tiene equivalente a CGEventTap. Los gestos del emulador van directamente al kernel del guest OS. La solucion: `adb shell getevent -lt` que streameea eventos raw del touchscreen virtual.

```
Usuario toca emulador
    |
getevent -lt                 — captura ABS_MT_POSITION_X/Y del kernel
    |
TouchCalibration             — transforma raw (0-32767) a screen (1080x2400)
    |
AgentBridge.tree()           — obtiene tree via socket JSON (~6ms)
    |
Hit-test en JSON tree        — busca elemento mas profundo + Button click-through
    |
Script .auto                 — tap "Confirmar"
```

Las coordenadas del kernel son raw hardware — el touchscreen virtual del emulador reporta valores en rango 0-32767 independientemente de la resolucion de pantalla. La calibracion se obtiene de `getevent -p` (rangos del device) y `wm size` (resolucion logica).

Un descubrimiento importante: en Jetpack Compose, los `TextView` no son clickables — el click handler vive en un `Button` hermano sin label. El resolver busca el `Button` mas cercano que contiene la posicion del `TextView` y tapea su centro.

## Selectores: la cascada de prioridad

```
1. identifier   — "loginBtn"           — inmune a cambios visuales
2. title        — "Iniciar sesion"     — estable si el texto no cambia
3. label        — "Login button"       — description de accesibilidad
4. label[N]     — "Confirmar[2]"       — segundo match, fragil
5. tapAt x y    — tapAt 540 1200       — ultimo recurso, coordenadas
```

El recorder marca los selectores fragiles con comentarios:

```auto
# no accessibilityIdentifier — selector may be fragile
tap "4"
```

Cuando hay multiples matches, intenta desambiguar:

1. **Role filter**: `tap[button] "Submit"` — solo toca AXButton, no AXStaticText
2. **Within scope**: `tap "Camera" within "Toolbar"` — busca dentro del subtree
3. **Occurrence**: `tap "Cerrar sesion[2]"` — segundo match

## waitFor: scripts state-aware

El recorder inyecta `waitFor` automaticamente en tres casos:

1. **Despues del launch** — el primer tap siempre tiene `waitFor` previo
2. **Gap de tiempo >1.5s** — indica transicion de pantalla
3. **Transicion tapAt → tap** — la pantalla cambio (el resolver paso de coordenadas a semantico)

```auto
launch "dev.autopilot.test.Explorea"

waitFor "Desbloquear con codigo"      # ← espera que la app cargue
tap "Desbloquear con codigo"
tap "1"
tap "2"
tap "3"
tap "4"
tapAt 438 2063                         # ← confirmar (boton sin label)
waitFor "Capturar"                     # ← transicion tapAt → tap
tap "Capturar"
waitFor "Mapa"                         # ← gap de tiempo
tap "Mapa"
```

`waitFor` con sintaxis `[N]` espera a que haya N matches:

```auto
tap "Cerrar sesion"                    # ← abre el dialogo
waitFor "Cerrar sesion[2]"             # ← espera que el dialogo aparezca (2 matches)
tap "Cerrar sesion[2]"                 # ← toca el boton del dialogo
```

Esto resuelve el problema de dialogos de confirmacion donde el mismo texto aparece en la lista Y en el dialogo.

## Deteccion de gestos

### iOS
- **Tap**: mouseDown + mouseUp < 0.5s, resuelve en mouseDown
- **Long press**: mouseUp > 0.5s despues de mouseDown
- **Double tap**: dos mouseDown en <300ms en el mismo selector
- **Scroll**: NO detectable (trackpad gestures bypassean CGEventTap)

### Android
- **Tap**: touchDown + touchUp < 0.5s, movimiento < 20px
- **Long press**: touchDown + touchUp > 0.5s
- **Swipe**: movimiento > 50px, calcula direccion
- **Double tap**: dos taps en <300ms en el mismo selector

### Lo que no detecta ninguno
- Scroll del trackpad en iOS (va directo al Simulator)
- Pinch/zoom (multi-touch)
- Drag & drop complejo

## Resultados: Explorea app

Flujo completo de 22 pasos: login con codigo → navegar 3 tabs → scroll → cerrar sesion → confirmar dialogo.

### Script grabado automaticamente (sin editar)

```
iOS:     0/5 (falla en scroll — un swipe no alcanza)
Android: 0/5 (falla en scroll — mismo problema)
```

### Script con ediciones manuales

```
iOS:     50/50 (100%) — 1 edicion: agregar swipe up extra
Android:  3/3 (100%) — 2 ediciones: swipe up extra + wait 0.5
```

### Ediciones necesarias

| Edicion | Por que | Ambas plataformas |
|---------|---------|-------------------|
| `swipe up` extra | Un swipe no scrollea suficiente | Si |
| `wait 0.5` post-scroll | El tree necesita tiempo para reflejar el scroll | Solo Android |

### Velocidad

| Metrica | iOS | Android (Agent) | Android (Legacy) |
|---------|-----|-----------------|------------------|
| Captura de evento | <1ms | <5ms | <5ms |
| Lectura de tree | ~15ms | ~6ms | ~2000ms |
| Replay 22 pasos | ~10s | ~5.5s | ~40s+ |

## El problema pendiente: scroll

El bloqueante para 100% replicabilidad sin edicion es el scroll. En ambas plataformas, el recorder no puede:

1. Detectar que el usuario scrolleo (iOS: trackpad bypass, Android: getevent detecta swipe pero no sabe cuantos pixels)
2. Saber cuantos swipes se necesitan para llegar a un elemento
3. Verificar que un elemento es VISIBLE (no solo que existe en el AX tree)

`scrollTo` tiene un bug: `search()` encuentra elementos offscreen porque el AX tree los incluye, asi que `scrollTo` retorna inmediatamente sin scrollear.

La solucion propuesta es `scrollUntilVisible` que verifica el frame del elemento contra el viewport antes de reportar "encontrado". Eso va en un PR futuro.

## Comparativa con la industria

| Aspecto | AutoPilot | Maestro Studio | Appium Inspector |
|---------|-----------|---------------|-----------------|
| Selector default | id/label | text/id | XPath |
| Latencia captura | <1ms | ~16ms (screenshot) | ~200ms (session log) |
| Bloqueo del device | No | Si (screenshot compare) | Si (WebDriver round-trip) |
| waitFor automatico | Si (gap + transicion) | Si (2s fijo) | No |
| Scroll recording | No | Si (visual) | Si (session log) |
| Role verification | Si (`[button]`) | No | No |
| Keyboard recording | Si (iOS) | No | No |
| Android + iOS | Si | Si | Si |
| Replicabilidad | **100%** (editado) | ~70-75% | ~40-55% |

El 100% de AutoPilot requiere 1-2 ediciones manuales. El 70-75% de Maestro es sin edicion pero con `waitForAnimationToEnd` de 2s que agrega 40s+ a un script de 20 taps.
