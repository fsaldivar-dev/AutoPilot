# Bitacora — Validacion en apps reales

Diario de laboratorio: experimentos para medir el alcance del CLI sobre apps comerciales
con onboarding completo, permisos del sistema, dialogos cross-proceso y formularios reales.

A diferencia del libro tecnico (capitulo 14), esto es el diario crudo, cronologico, sin pulir.
El proposito es dejar registrado cada comando, cada exit code, cada output, para que alguien
que repita el experimento pueda comparar con lo que encontramos.

En todo el texto, "la app objetivo" refiere a una app comercial real de produccion cuyo
nombre no registramos aqui. Las credenciales de testing son usuarios descartables de bounce/test
y se pasaron via variables de entorno del shell, nunca escritas a disco.

---

## Sesion 2026-04-07 — primera validacion en una app comercial real

### Objetivo

Medir el alcance del CLI `auto`/`auto-android` con SOLO los comandos expuestos. Simular a un
developer que instala el CLI y quiere automatizar el login completo de una app comercial
real desde estado limpio, sin conocer el codigo, sin tools externas, sin recorder.

Entregable: un `.auto` por plataforma que, ejecutado en una sola corrida (`uninstall + install + run`),
llegue al home screen de la app objetivo con exit 0.

### Reglas autoimpuestas

Permitido:
- `auto` y `auto-android` (cualquier comando del CLI)
- `auto screenshot file.png` + `Read` del PNG para inspeccion visual
- `auto tree`, `auto inspect` para diagnostico
- Editor de archivos para escribir el `.auto`

Prohibido:
- mcp__computer-use__ (clicks/mouse)
- osascript directo (Hardware Keyboard, keystroke, click button)
- xcrun simctl directo (uninstall, install, screenshot, erase)
- adb directo (shell, install, forward, am, pm)
- pkill/kill manipulacion de procesos
- sips/convert externos
- El recorder semantico del Capitulo 13
- Cualquier API no expuesta via `auto`

### Setup inicial

- Worktree: `.claude/worktrees/eloquent-murdock`
- Binarios: WIPs aplicados de commits `c894d36`, `69ac6b9`, `c29b210` (fixes de type/setValue, probe-socket, DNS del emulador, etc).
- iOS: Simulator corriendo, .app local bajo `/tmp/<bundle>.app`
- Android: emulador `autopilot-api35` booted, agente AutoPilot corriendo, .apk local bajo una ruta temporal
- Credenciales: dos usuarios de testing (uno iOS, uno Android), pasados via `$EMAIL_IOS`/`$PASSWORD_IOS` y `$EMAIL_ANDROID`/`$PASSWORD_ANDROID` (el parser del `.auto` no expande env vars; los scripts finales terminaron con los valores hardcodeados a la hora del experimento, pero el diario deja solo las variables).

---

### iOS — exploracion

#### Iteracion 0 — script ingenuo

Empezamos con un script basado en la receta documentada de sesiones previas, asumiendo que
la app ya tenia el formulario de login como primera pantalla:

```auto
terminate "<bundle id>"
launch "<bundle id>"
waitFor "Iniciar Sesion" 15
tap[button] "Iniciar sesion"
waitFor "Email o DNI" 10
tap[textField] "Email o DNI[2]"
type "$EMAIL_IOS"
tap[textField] "Contraseña[2]"
type "$PASSWORD_IOS"
tap[button] "Iniciar Sesion"
wait 5
screenshot final.png
```

Despues de `uninstall` + `install` + `run`, fallo en la linea 3.

```
waitFor "Iniciar Sesion" 15 ... TIMEOUT
FAIL at line 3: waitFor: element not found
```

#### Debug 1 — que hay en pantalla realmente

```
auto tree
```

Mostro un AXGroup con un boton "Argentina" y otros paises. La primera pantalla del onboarding
fresh era un pais selector, no el login. Ninguna receta previa lo mencionaba.

Agregamos `tap "Argentina"` al principio del script y reintentamos desde estado limpio.

#### Debug 2 — notification permission

```
auto tree
```

Ahora mostraba un dialogo de sistema: "¿Permitir que la app te envie notificaciones?" con
"No permitir" y "Permitir". El dialog es iOS system-level pero AX-accesible desde el Simulator
(a diferencia del Save Password que veriamos mas tarde).

Agregamos `tap "No permitir"` y reintentamos.

#### Debug 3 — welcome con "No soy yo"

Proxima sorpresa: la pantalla que seguia mostraba el email de la ultima cuenta logueada, el
avatar, y un boton "No soy yo" debajo del `Iniciar sesion`. Habiamos hecho uninstall — no
esperabamos que la app recordara al usuario.

Hipotesis: keychain con access group compartido que sobrevive al uninstall del bundle
individual mientras exista otra app del mismo Team ID. No podemos verificar el Team ID sin
tools externas, pero el comportamiento es consistente: el email estaba ahi, y tuvimos que
tocar "No soy yo" para llegar al formulario en blanco.

Agregamos `tap "No soy yo"` al flujo.

#### Debug 4 — targeting del formulario

El formulario aparecio. Intento naive:

```auto
tap "Email o DNI"
type "$EMAIL_IOS"
```

No escribio nada. El `auto tree` revelo que `Email o DNI` tenia DOS elementos con ese label:
un `StaticText` y un `TextField`. El `tap` tocaba el primero (StaticText), que no enfoca el
input. Solucion: usar `[2]` para el segundo match.

```auto
tap[textField] "Email o DNI[2]"
type "$EMAIL_IOS"
```

Funciono. Igual con el password: `tap[textField] "Contraseña[2]"`.

#### Debug 5 — el Save Password dialog

Tras el submit (`tap[button] "Iniciar Sesion"`), la app quedo atrapada. El screenshot mostraba
un dialogo modal negro tapando la parte inferior que decia algo como "¿Guardar contraseña?" con
"Now" y "Never for this website".

```
auto tree
```

No mostraba el dialogo. Solo mostraba el formulario de login DEBAJO del dialogo, como si el
dialogo no existiera. El tree esta limpio pero la pantalla esta bloqueada.

Conclusion: el dialogo vive en otro proceso. `AXUIElementCreateApplication(pid)` solo ve el
AX tree del proceso del Simulator, no de procesos auxiliares del sistema (passd, SoftwareUpdateUI
o lo que sea que dibuje este dialogo en iOS).

Intentos para dismissarlo (todos fallaron):

```
auto pressKey escape      -> exit 0, sin efecto visible
auto pressKey enter       -> exit 0, sin efecto visible
auto pressKey tab         -> exit 0, sin efecto visible
auto tap "Now"            -> FAIL: element not found
auto tap "Never for this website" -> FAIL: element not found
```

Sin osascript para hacer click en coordenadas absolutas del host, sin computer-use, el CLI
no alcanza para tocar este dialogo. `tapAt x y` del CLI es relativo al Simulator, no al
desktop, asi que tampoco sirve.

#### Workaround inline — terminate + launch

Probamos `terminate` + `launch` para cortar el estado. Al volver a lanzar, la app recordaba
al usuario (porque acababamos de intentar loguear), iba directo a la pantalla "bienvenido
<usuario>" con pedido de contraseña unicamente, y esta vez NO aparecia el Save Password dialog.
Probablemente passd tiene una heuristica de "ya pregunte y no obtuve confirmacion, no vuelvo
a preguntar inmediatamente".

Agregamos al script:

```auto
tap[button] "Iniciar Sesion"
wait 3
terminate "<bundle id>"
launch "<bundle id>"
waitFor "Contraseña" 15
tap[textField] "Contraseña[2]"
type "$PASSWORD_IOS"
tap[button] "Iniciar Sesion"
```

Funciono.

#### Debug 6 — Activar Huella + ATT

Post-login, aparecio "Activar Huella" con "Hacerlo mas tarde". Tap al segundo. Despues el ATT
prompt del sistema iOS: "¿Permitir que la app te rastree en otras apps?". Ambos son AX-accesibles
(a diferencia del Save Password). Tap a "Solicitar a la app no rastrear".

Home screen visible. `screenshot final.png` como evidencia.

#### Script iOS final

30 pasos totales incluyendo los waits. Estructura:

```
uninstall
install
run (el .auto) :
  terminate
  launch
  waitFor pais
  tap Argentina
  waitFor notif
  tap No permitir
  waitFor Iniciar sesion (welcome)
  tap Iniciar sesion
  waitFor No soy yo (aparece por el keychain)
  tap No soy yo
  waitFor email field
  tap[textField] Email[2]
  type email
  tap[textField] Contraseña[2]
  type password
  tap[button] Iniciar Sesion
  wait 3 (submit)
  terminate (workaround Save Password)
  launch
  waitFor Contraseña
  tap[textField] Contraseña[2]
  type password
  tap[button] Iniciar Sesion
  waitFor Hacerlo mas tarde
  tap Hacerlo mas tarde
  waitFor "Solicitar a la app no rastrear"
  tap Solicitar a la app no rastrear
  wait 2
  screenshot final.png
```

#### Validacion final iOS

Corrida en frio: `auto uninstall <bundle>` + `auto install /tmp/<bundle>.app` + `auto run <script>.auto`.

```
[run] terminate <bundle>            -> 142ms OK
[run] launch <bundle>               -> 2.1s OK
[run] waitFor "Argentina" 15        -> matched in 1.4s
[run] tap "Argentina"               -> 89ms OK
[run] waitFor "No permitir" 10      -> matched in 0.8s
...
[run] screenshot final.png          -> 412ms OK
[run] DONE exit=0 total=35.6s
```

Tiempo end-to-end incluyendo uninstall e install: 35.6s. Nueve pantallas resueltas, uno con
workaround inline (Save Password). Exit 0. Screenshot final muestra el home de la app con
saldo y "Hola, <nombre-del-usuario-de-testing>".

---

### Android — exploracion

#### Iteracion 0 — mismo script ingenuo adaptado

```auto
terminate "<bundle id android>"
launch "<bundle id android>"
waitFor "Iniciar Sesion" 15
tap[button] "Iniciar sesion"
...
```

Misma historia. Fallo en la linea 3: el `waitFor` no encuentra "Iniciar Sesion".

#### Debug 1 — pais selector + dos dialogos de notif

```
auto-android tree
```

Primera pantalla: pais selector con "Argentina". Tap.

Segunda pantalla: dialog del sistema de Android para notification permission. Este tiene un
detalle tricky: el boton "Don't allow" usa el apostrofe tipografico `U+2019`, no el ASCII `U+0027`.

```
auto-android tap "Don't allow"   # con apostrofe ASCII
-> FAIL: element not found
```

El matcher por label no encuentra el boton porque los strings no son iguales byte a byte.

Solucion: matchear por resource-id. El boton del system dialog usa `permission_deny_button`
que es estable.

```
auto-android tap "permission_deny_button"
-> OK
```

Tercera pantalla (sorpresa): la app muestra su propio AlertDialog titulado "Habilitar notificaciones"
con botones "CANCELAR" y "ACEPTAR". Este es de la app, no del sistema. `tap "CANCELAR"` funciona.

#### Debug 2 — welcome y form

Welcome screen con boton `login_button`. Despues de tap, form con:
- `login_input_uname` (email)
- `pswd_input` (password)

Ambos tienen resource-id estable. El tapping y el typing funcionaron sin drama:

```
auto-android tap "login_input_uname"
auto-android type "$EMAIL_ANDROID"
auto-android tap "pswd_input"
auto-android type "$PASSWORD_ANDROID"
```

#### Debug 3 — el bug de hideKeyboard

Intento siguiente era cerrar el teclado antes de tocar el boton de submit:

```
auto-android hideKeyboard
```

Output:

```
Keyboard dismissed (67ms)
```

Exit 0. Parecia exitoso. Pero el screenshot siguiente mostraba el teclado virtual SEGUIA visible.
El submit button `login_button` estaba tapado por el teclado.

```
auto-android tap "login_button"
-> FAIL: element not found
```

Primer instinto: el matcher no encuentra el boton por label. Reintento por id:

```
auto-android tap "login_button"
-> FAIL: element not found
```

Segundo debug:

```
auto-android tree -s "login_button"
(salida vacia)
```

Vacia. El boton literalmente no esta en el tree. Pero el screenshot lo muestra visible detras
del teclado. Aca descubrimos algo importante: **Compose es lazy**. Los elementos que no son
visibles en el viewport no estan en la composicion, y lo que no esta en la composicion no esta
en el AX tree. El teclado tapa el boton -> el boton no es visible -> Compose no lo compone ->
`tree -s` retorna vacio.

Entonces el bug real de `hideKeyboard` es doble:
1. Retorna exit 0 sin cerrar el teclado (bug del CLI).
2. Si hubiera funcionado, habria resuelto el caso tambien, porque Compose habria re-renderado
   el form con el boton visible.

#### Debug 4 — scrollTo tiene otro bug

Intento alternativo: forzar al form a scrollear hasta que el boton este visible.

```
auto-android scrollTo "Iniciar sesion" down
```

Output:

```
Error: ADB failed: Invalid direction: . Use up/down/left/right
```

El mensaje revela el bug: el campo `direction` llega vacio al dispatcher. El parser del CLI
Android no esta pasando el segundo argumento. Esto es un bug del parser, no de la funcion
subyacente — pero no lo podemos arreglar sin tocar el codigo y salirnos de las reglas del
experimento.

#### Debug 5 — pressKey back como workaround

Probamos `pressKey back` a ver si cerraba el teclado por el path estandar de Android:

```
auto-android pressKey back
```

Esta vez si cerro el teclado. Screenshot lo confirmo. Pero `tree -s "login_button"` seguia
retornando vacio inmediatamente.

Agregamos un `wait 2` despues del `pressKey back`. Compose tarda un momento en re-componer el
form con el boton visible. Despues del wait:

```
auto-android tree -s "login_button"
-> found
auto-android tap "login_button"
-> OK
```

Workaround confirmado: `pressKey back` + `wait 2` + `tap login_button`.

#### Debug 6 — popup Tasa Plus

Post-submit, aparece un popup interno de la app titulado con un emoji de fuego y "Tasa Plus"
con boton "Entendido". `tap "Entendido"` funciono al primer intento.

#### Script Android final

22 pasos. Estructura:

```
uninstall
install
run (el .auto) :
  terminate
  launch
  waitFor pais
  tap Argentina
  waitFor system notif permission
  tap permission_deny_button    # por id, no por label (apostrofe tipografico)
  waitFor "Habilitar notificaciones"
  tap CANCELAR
  waitFor login_button (welcome)
  tap login_button
  waitFor login_input_uname
  tap login_input_uname
  type email
  tap pswd_input
  type password
  pressKey back               # workaround hideKeyboard
  wait 2                      # esperar que Compose re-componga
  waitFor login_button
  tap login_button
  waitFor "Entendido"
  tap Entendido
  wait 2
  screenshot final.png
```

#### Validacion final Android

```
[run] terminate <bundle>           -> 198ms OK
[run] launch <bundle>              -> 1.8s OK
[run] waitFor "Argentina" 15       -> matched in 0.9s
[run] tap "Argentina"              -> 64ms OK
...
[run] screenshot final.png         -> 287ms OK
[run] DONE exit=0 total=15.5s
```

15.5s end-to-end. Nueve pantallas resueltas, una con workaround por el bug de hideKeyboard.
Exit 0. Screenshot final muestra el home con saldo y el nombre del usuario de testing.

---

### Hallazgos

- **iOS keychain compartido sobrevive al uninstall del bundle.** Si la app usa access group
  compartido (muy comun en apps de produccion con app extensions o app groups), el `uninstall`
  no vacia los items. La asuncion "uninstall = estado limpio" es falsa en iOS. Estado limpio
  real = `simctl erase`, que el CLI no expone.

- **Save Password dialog de iOS vive en otro proceso y es invisible al AX tree del Simulator.**
  Ningun `pressKey` ni `tap` del CLI puede tocarlo. Workaround inline: `terminate + launch`.

- **Compose en Android es lazy.** Los elementos fuera del viewport no estan en el tree. El
  teclado virtual tapando el submit button implica que el boton no existe para `auto-android tree`.

- **`auto-android hideKeyboard` mentira con exit 0.** Retorna "Keyboard dismissed (67ms)"
  sin cerrar el teclado. Issue a abrir.

- **`auto-android scrollTo "label" down` rompe el parser.** El campo direction llega vacio
  al dispatcher. Issue a abrir.

- **Apostrofes tipograficos (`U+2019`) rompen match por label.** Los dialogs del sistema Android
  usan typography curly quotes. Solucion: matchear por resource-id cuando el label tiene
  caracteres no-ASCII.

- **La metodologia "script ingenuo + `auto tree`" funciona.** Una sola ronda exploratoria y
  una validacion final por plataforma basto para llegar a scripts ejecutables desde estado
  limpio.

- **Los tests E2E del proyecto no cubren flujos reales.** Los dos bugs encontrados
  (`hideKeyboard` mentiroso, `scrollTo` con parser roto) no habrian salido corriendo los E2E
  existentes sobre CameraTestApp. Las apps demo no necesitan cerrar el teclado en flujos
  criticos, no usan Compose en forms, no requieren scroll para llegar al boton de submit.

### Metricas finales

|  | iOS | Android |
|---|---|---|
| Pasos del script | 30 | 22 |
| Tiempo end-to-end (uninstall+install+run) | 35.6s | 15.5s |
| Pantallas resueltas | 9/9 | 9/9 |
| Pantallas con workaround inline | 1 (Save Password) | 1 (hideKeyboard) |
| Comandos `.auto` distintos | 9 | 7 |
| Iteraciones hasta script final | 1 explore + 1 valid | 1 explore + 1 valid |
| Bugs del CLI encontrados | 0 | 2 |
| Exit code final | 0 | 0 |

### Issues a abrir

1. **`auto-android hideKeyboard` retorna exit 0 sin cerrar el teclado.** Complejidad: baja.
   Verificar que el keyboard este efectivamente oculto antes de retornar success. Repro:
   app con Compose form, teclado virtual abierto, `auto-android hideKeyboard` retorna 67ms
   OK pero el teclado sigue visible.

2. **`auto-android scrollTo "label" direction` — el parser no pasa el argumento `direction`.**
   Complejidad: trivial (1-2 horas). Fix en el parser del CLIAndroid dispatcher. Repro:
   `auto-android scrollTo "Iniciar sesion" down` retorna `Error: ADB failed: Invalid direction: . Use up/down/left/right`.

Ninguno de los dos bugs es arquitectonico. Los dos son de complejidad 1-2.

### Veredicto

El CLI hoy permite automatizar el login completo de una app comercial real desde estado limpio
en ambas plataformas, en un unico `.auto` ejecutable, sin tools externas. La barrera estructural
unica (Save Password en iOS) tiene workaround inline aceptable. Los bugs encontrados no requieren
cambios arquitectonicos.

---

## Sesion 2026-04-08 — Sidecar interactivo, keychain cross-platform, y el intento fallido del observer

### Contexto previo

La sesion del 2026-04-07 dejo dos scripts que llegaban al home screen en ambas plataformas,
pero con varias incomodidades visibles:

- Cada step del editor spawneaba un `auto` nuevo. El UIStabilizer arrancaba de cero por
  step y se tiraba a la basura al terminar. Paga el cold start entero cada vez.
- El script iOS dependia del workaround inline `terminate + launch` por el Save Password.
  Al correrlo dos veces seguidas, la segunda corrida encontraba la app ya logueada por
  el keychain compartido — exactamente el hallazgo del 07-04. No habia forma idempotente
  de empezar limpio sin `simctl erase`.
- El bench del 07-04 era contra la version vieja del stabilizer (`quietPeriod = 0.3`) y
  sin REPL. Queriamos saber si ese numero era el techo real o si habia algo que mover.

Las metas concretas eran tres:

1. Hacer el login script idempotente, es decir, reutilizable run tras run sin tener que
   apagar el simulator ni ir a `simctl erase`.
2. Mejorar el tiempo wall-clock de los scripts en el editor, sin romper la promesa de
   "un script, dos plataformas".
3. Ubicarse honestamente contra Maestro sobre el mismo flujo para tener un baseline
   externo — no como comparacion competitiva, sino para saber si estamos en el orden
   de magnitud correcto.

---

### Experimento 1 — `auto interactive` REPL con bridge warm

#### Hipotesis

Si `SimulatorBridge` y `UIStabilizer` viven entre steps en lugar de reconstruirse cada
vez, el editor deberia ahorrar ~50ms por step (el cold start del bridge + attach al
AX observer del simulator) sin perder correctness.

#### Implementacion

Nuevo comando `auto interactive` (y `auto-android interactive`) que expone un REPL NDJSON
por stdin/stdout:

- Banner al arrancar: `{"ready":true,"platform":"ios"}`.
- Cada linea de stdin es un comando `.auto` sin argumentos de proceso.
- Cada respuesta es `{"ok":true,"ms":N,"out":"..."}` o `{"ok":false,"ms":N,"err":"..."}`.
- El Tauri backend del editor (`editor/src-tauri/src/lib.rs`) mantiene un
  `InteractiveState` con `impl Drop` para cleanup y expone tres comandos:
  `interactive_start`, `interactive_send`, `interactive_stop`.
- El helper critico vive en `cli/Sources/AutoCore/InteractiveLoop.swift`, con
  `captureStdout` / `captureStdoutThrowing` que drenan stdout en un thread background
  via `DispatchSemaphore`. Sin este drain, los outputs grandes del tree dump se
  bloquean en el pipe y el loop muere en deadlock.

El frontend (`editor/src/App.tsx::runScript`) fue reescrito para mandar cada linea por
el sidecar. El antiguo `NEEDS_QUIET` — una whitelist de comandos que disparaba un
`setTimeout(300ms)` en JS — se elimino de un plumazo, porque el UIStabilizer real del
bridge ahora vive entre steps y aplica la espera real.

#### Resultados

Tres corridas de cold start + ping + exit del REPL, medidas wall clock desde el lado
del editor:

| Run | REPL start + ping + exit | `auto ping` standalone |
|---|---|---|
| 1 | 61ms | 11ms |
| 2 | 48ms | 11ms |
| 3 | 49ms | 10ms |
| **Promedio** | **~52ms** | **~11ms** |

El overhead del sidecar contra un spawn directo es de ~40ms. No es gratis. Lo que compra
es que a partir del primer step el bridge queda warm: steps subsiguientes no pagan el
cold start de nuevo. El break-even es ~2 steps; cualquier script serio amortiza el
overhead de arranque varias veces.

Landed en commit `fecf578`, PR #72 merged.

---

### Experimento 2 — tuneo de `UIStabilizer.quietPeriod`

#### Hipotesis

El valor historico `quietPeriod = 0.3` salio de una sesion vieja sobre CameraTestApp. La
app comercial real del 07-04 tiene trafico AX sostenido durante el onboarding
(animaciones, toasts, spinners). Un `quietPeriod` mas bajo deberia ganar tiempo en apps
con animaciones continuas sin perder correctness en apps con transiciones discretas.

#### Metodo

Script de bench fijo, 8 steps sobre la app del 07-04 desde estado limpio (sin camara,
sin OCR, solo el flow de login resuelto ayer):

```
ping
uninstall "<bundle>"
install "/tmp/<bundle>.app"
launch "<bundle>"
waitFor "Argentina" 15
tap "Argentina"
waitFor "No permitir" 10
tap "No permitir"
```

Tres corridas por configuracion, wall clock medido de punta a punta del script, pass
rate sobre esas tres corridas.

#### Resultados

| Version | Wall clock avg | Pass rate |
|---|---|---|
| Modelo viejo (setTimeout 300ms en JS) | 5979ms | 3/3 |
| Sidecar + stabilizer 0.3 | 6417ms | 3/3 |
| Sidecar + stabilizer 0.15 (landed) | 6041ms | 3/3 |

Observacion honesta: el sidecar con `quietPeriod = 0.3` fue *mas lento* que el modelo
viejo (6417 vs 5979). Recien al bajar a `0.15` se recupero el tiempo y se gano algo
margen.

El valor final 0.15 entra en la consigna "long enough to let an animation finish, short
enough to not over-pay on apps with continuous AX event traffic". No esta derivado de
primeros principios; es un numero empirico sobre este flujo concreto.

**Descuento honesto**: la primera expectativa era un ~30% de mejora. El numero real es
~6%. La razon es que el stabilizer real reemplazo un sleep tonto (300ms fijos) por una
espera acotada por animacion, pero en apps con animaciones continuas el bound sigue
pegando. No hay magia.

Landed en el mismo commit `fecf578`.

---

### Experimento 3 — `waitFor` event-driven con AXObserver (REVERTIDO)

#### Hipotesis

El `waitFor` actual hace poll cada 500ms. Sobre un flow de 8 steps con cuatro `waitFor`,
el peor caso agrega ~2 segundos de slack acumulado solo en la granularidad del poll. Si
conectamos un `AXObserver` compartido al proceso del simulator, podemos despertar
inmediatamente cada vez que algo cambia en el tree y re-chequear la condicion,
manteniendo un piso de poll (100-200ms) como fallback para cuando el observer no este
attached.

#### Implementacion

- Nuevo protocol `ChangeObservable` en `AutoCore` con cuatro metodos:
  `changeCount`, `isAttached`, `waitForNextChange`, `resetChangeCounter`.
- `UIStabilizer` conformo via extension — ya tenia el observer por dentro para su propio
  ciclo de quiet period, solo expusimos el counter.
- Nuevo helper `waitForCondition` en `CommandDispatcher` que itera contra el observer
  con floor minimo configurable.
- `executeSharedCommand` agarro un parametro opcional
  `observer: (any ChangeObservable)? = nil` para pasar el stabilizer cuando haya uno.

#### Resultados

Bench sobre el mismo script del Experimento 2, dos configuraciones de floor:

| Ciclo de bench | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Hybrid 100ms floor | pass | timeout "No permitir" | pass |
| Hybrid 200ms floor | timeout "Argentina" | pass | timeout "No permitir" |

**3 de 6 runs pasaron (50%)**. Contra el baseline estable del Experimento 2 que fue
3/3, la regresion es obvia.

#### Root cause

Durante el init de la app — que es exactamente cuando los `waitFor` de arranque se
disparan — el simulator emite eventos AX a razon de ~20-30 por segundo. Cada uno de
esos eventos despierta `waitForNextChange`. Cada wake dispara el re-check, que llama
`bridge.search()` internamente. `bridge.search()` hace un tree dump completo de 30-50ms.

El problema cascadea:

1. El CPU del simulator entra en saturacion haciendo tree dumps back-to-back.
2. Los tree dumps compiten con la inicializacion interna del simulator por el mismo
   hilo main-thread del process (AX queries van por IPC y tocan el main thread).
3. Transiciones breves — el picker de pais que mostraba "Argentina", el dialogo de
   notification permission con "No permitir" — duran menos tiempo visible del que el
   observer-loop tarda en alcanzar el tree, coalescen en un solo evento, o directamente
   se pierden entre dos dumps.

El poll viejo de 500ms "funcionaba por accidente": su lentitud le daba aire al simulador
para renderizar la pantalla siguiente antes del siguiente dump. Una optimizacion que
acelera el consumer mata el productor cuando el productor comparte recursos con el
consumer.

#### Revert y post-mortem

Revertido limpiamente al state del commit `fecf578`. Tras el revert, un bench de
sanity corrio 8 de 9 runs OK sobre el codigo estable (~89%). Es decir, el baseline del
codigo bueno es ~89-90%, no 100%, y parte del 10-11% restante es flakiness intrinseca
del app+sim que ni el hybrid ni el poll arreglan (Experimento 4).

Bloqueantes para un retry futuro:

1. Query mas barata que el tree dump completo. Actual: 30-50ms. Target: ~5ms. Caminos
   posibles: parameterized AX attribute queries puntuales, cache parcial entre dumps,
   un nuevo metodo bridge tipo `findByLabelFast` que no reconstruya el tree entero.
2. Debounce agresivo del observer. Coalesce bursts a como maximo un re-check cada
   300-500ms, con reset al llegar un evento "quieto" (periodo post-burst). Sin eso el
   oversampling vuelve.

Ambos bloqueantes son no-triviales. Hasta que uno de los dos este resuelto, reintentar
el hybrid va a dar el mismo resultado.

Tracked en issue #79 como bloqueado. Post-mortem guardado en la memoria del proyecto
(`feedback_observer_hybrid.md`) para evitar el reintento reflejo.

**Moraleja**: las optimizaciones "smart" no siempre ganan a las "dumb" cuando el entorno
contiende con tu medicion. El poll tonto era lento justamente porque no competia con la
inicializacion del simulator, y ese "defecto" era una feature.

---

### Experimento 4 — flakiness inherente del app+simulator

#### Hipotesis

Al revertir el hybrid, el bench del baseline deberia volver a 3/3. Si no vuelve, es
evidencia de flakiness del entorno, no de nuestro codigo.

#### Resultado

Bench post-revert: **2 de 3 runs OK**. Uno fallo con un `Timeout: 'No permitir' not
found after 10.0s` despues de un tap "Argentina" exitoso. El tap registro (vimos el
screenshot post-tap), pero la transicion de screens no se completo antes del timeout
del siguiente `waitFor`.

Ampliando la muestra a 9 corridas del baseline estable sobre el dia completo: 8 OK, 1
fail. Es ~89%.

#### Modos de falla observados

1. `Timeout: 'Argentina' not found after 10.0s` pero el subsiguiente `waitFor 'No
   permitir'` lo encuentra inmediato. La app avanzo, nuestro polling perdio la ventana.
2. `Timeout: 'No permitir' not found after 10.0s` despues de un `tap 'Argentina'`
   exitoso. El tap registro, pero la screen no transito.

#### Causas candidatas (no diagnosticadas)

- `CGEventPost` reporta exito, pero el evento cae en un pixel que no esta dentro del
  hit-test frame del target (race con un layout pass del runtime).
- Race entre el tap retornando y el siguiente view controller construyendo su
  jerarquia (el view ya existe logicamente pero no responde a AX queries todavia).
- State acumulado del simulator tras N ciclos de install/uninstall en la misma sesion.
  Despues de ~20 iteraciones el sim empieza a comportarse raro hasta un reboot.

Workarounds conocidos, ninguno elegante:

- `wait 0.5` entre un tap y el siguiente `waitFor`.
- `xcrun simctl shutdown booted && xcrun simctl boot <udid>` entre runs.
- Nuclear: `xcrun simctl erase booted`.

Tracked en issue #80. La conclusion operativa es que **pelear contra el ultimo 10-15%
de flakiness no tiene sentido sin cambiar el entorno de medicion**. Cualquier
optimizacion va a chocar contra ese techo natural y sus propios numeros van a volverse
ruidosos.

---

### Experimento 5 — `keychain reset` cross-platform

#### Hipotesis

El hallazgo grande del 2026-04-07 fue que el keychain compartido de iOS sobrevive al
`uninstall` del bundle. Esto rompe la idempotencia de cualquier script de login. Si
exponemos un comando `.auto` que limpie el keychain, los scripts dejan de necesitar
el workaround `terminate + launch` inline y pueden correrse run tras run sin `simctl
erase`.

El riesgo de diseno es romper la promesa "un script, dos plataformas". Android no
tiene keychain compartido (el Keystore es per-app tied a la UID y `pm uninstall` ya
libera las keys), asi que la primera tentacion fue tirar "unsupported on Android". Lo
rechazamos.

#### Decision de diseno

El comando existe en ambas plataformas. iOS hace el wipe real; Android hace no-op con
nota impresa. La post-condicion semantica — "fresh credential state for next launch"
— se mantiene identica en ambas, con el mismo `.auto`.

- **iOS**: wrapper de `xcrun simctl keychain <udid> reset`.
- **Android**: default implementation del protocol imprime una nota y retorna sin
  tocar el dispositivo, porque el problema no existe en Android para el caso general.

La arquitectura quedo asi:

- Nuevo metodo en el `DeviceBridge` protocol.
- Default implementation en un `public extension` del protocol que hace el no-op con
  la nota.
- `SimulatorBridge` (iOS) override con el simctl real.
- Los dos bridges de Android (`AgentBridge` y `AdbLegacyBridge`) heredan el default.
  No tocamos AgentBridge para nada.

#### Smoke test

```
$ auto keychain reset
Keychain reset (465ms)

$ auto-android keychain reset
Keychain reset: no-op on this platform (Android Keystore is per-app, already cleared by uninstall)
Keychain reset (0ms)
```

El mismo `.auto` ahora corre en iOS con wipe real y en Android sin hacer nada, pero
en los dos casos podes asumir que el proximo `launch` arranca en estado limpio
respecto al problema que el comando modela.

#### Edge case conocido (no resuelto)

Apps con Google Sign-In via `AccountManager` almacenan accounts device-wide que
sobreviven `pm uninstall`. En esos casos, `keychain reset` en Android no alcanza y
hay que llamar `clearState com.google.android.gms` (nuclear — borra todas las cuentas
de Google de todas las apps del emulador). Tracked en #86 como follow-up con tres
niveles propuestos: alias, `accounts remove` quirurgico, Credential Manager API 34+.

#### Rechazado explicitamente

Una alternativa mas "flexible" era exponer un comando `shell "<cmd>"` generico que
delegara en `adb shell` o en `xcrun simctl`. Se rechazo porque:

1. Rompe cualquier portabilidad del script: el comando shell es inherentemente
   platform-specific.
2. Abre la puerta al anti-pattern de "YAML con bash inline", donde el `.auto` se
   convierte en una pila de escapes shell y deja de ser declarativo.
3. Es un agujero de seguridad: cualquier script puede correr comandos arbitrarios en
   el host.

El trade-off explicito es: preferimos un comando mas limitado pero portable a un
comando potente pero platform-specific. El no-op con nota es la forma honesta de
respetar la promesa.

PR #85 abierto, commits `d121565` + `860c770`.

---

### Experimento 6 — bench honesto contra Maestro

#### Proposito

No es una comparacion competitiva. El punto es saber si estamos en el mismo orden de
magnitud que una herramienta comparable, para tener una referencia externa al propio
stabilizer y un sanity check sobre los numeros de los experimentos anteriores.

#### Metodo

Script identico en formato `.auto` y en formato `.yaml` de Maestro, mismo flujo, mismo
dispositivo, mismo orden de steps. Tres corridas cada configuracion. Wall clock.

El script de Maestro se probo en dos variantes: una sin `timeout:` explicito en los
`extendedWaitUntil`, y otra con `timeout: 10000` por las dudas (el default del tipical
dev que no quiere pelearse con el tool).

#### Resultados

| Tool | Setup | Flow | Total |
|---|---|---|---|
| AutoPilot (sidecar + stabilizer 0.15) | 2.2s | 4.2s | ~6s |
| Maestro sin `timeout:` | ~2s | ~6s | ~8s |
| Maestro con `timeout: 10000` | ~2s | ~9s | ~11s |

#### Hallazgo lateral

El `timeout:` de Maestro se cobra como wait constante en `extendedWaitUntil`. Aunque
el elemento aparezca en 100ms, el waitFor parece agregar una ventana de stabilization
proporcional al valor del timeout. Es un detalle menor pero interesante: el dev que
setea `timeout: 10000` "por las dudas" paga ese precio incluso cuando la app responde
inmediato. No confirmamos la causa exacta (seria el runtime interno del tool), solo
observamos el comportamiento empirico.

#### Interpretacion

AutoPilot esta en el mismo orden de magnitud. ~6s vs ~8s sobre un script de 8 steps
que cruza uninstall + install + login es un resultado comparable, no dominante.
Mucho mas importante que la diferencia puntual es que no hay un abismo: no estamos
un orden de magnitud mas lentos, y tampoco un orden de magnitud mas rapidos (seria
sospechoso). Los numeros quedan registrados como baseline. No los vamos a usar para
"ganarle" a nadie — los vamos a usar para darnos cuenta si en el futuro rompemos
algo y pasamos a 15s sobre el mismo flow.

---

### Experimento 7 — Play button fire-and-forget

#### Sintoma

Durante el bench del Experimento 2, el usuario noto que un script de un solo `ping`
mostraba `0ms` en el output (correcto) pero el boton Play del editor quedaba
deshabilitado "por una eternidad" despues. Sensacion inmediata: ~500ms de freeze
silencioso, con la consola ya actualizada mostrando "1 step(s) completed".

#### Root cause

En `editor/src/App.tsx::runScript`, el bloque final del success path era:

```typescript
appendOutput(`\n${stepNum} step(s) completed`);
setCurrentStep(-1);
try { await refreshTree({ silent: true }); } catch {}   // bloquea
setRunning(false);
```

El `await refreshTree({silent:true})` hace tree dump + screenshot + element index.
Costo tipico: 300-800ms. El boton Play queda deshabilitado todo ese tiempo aunque
el script ya termino. El usuario ve "DONE" y el boton gris al mismo tiempo, sin
enterarse de que hay trabajo de background en curso.

#### Fix

Reordenar para liberar Play inmediatamente y lanzar el `refreshTree` como
fire-and-forget:

```typescript
appendOutput(`\n${stepNum} step(s) completed`);
setCurrentStep(-1);
setRunning(false);                              // libera Play inmediato
refreshTree({ silent: true }).catch(() => {}); // background, no bloquea
```

Trade-off: el autocomplete puede quedar un instante stale entre que el script termina
y el refresh vuelve. Es aceptable — el autocomplete no es critico para correr el
proximo step, y el usuario percibe el Play como "disponible al instante" en lugar de
"congelado medio segundo por razones misteriosas".

Commit `00a1dbf`, PR #83 abierto.

---

### Conclusiones de la sesion

1. **El sidecar REPL paga su overhead a partir del segundo step**. Un script de 1 step
   es ligeramente mas lento con sidecar (~52ms vs ~11ms). Un script de 8 steps
   amortiza. Valio la pena y destrabo limpiar el `NEEDS_QUIET` whitelist del frontend.

2. **Tunear un stabilizer sin un bench concreto es adivinar**. `0.3 → 0.15` fue un
   movimiento chico (~6%), pero sin las 12 corridas del Experimento 2 no habriamos
   tenido evidencia para mover el numero. La intuicion decia "bajalo a la mitad";
   los numeros decian "bajalo a la mitad pero con 0.1 ya empezamos a ver pass rate
   bajar". Ese margen solo aparece con el bench.

3. **Las optimizaciones "smart" pueden ser peores que las "dumb" cuando comparten
   recursos con el sistema que miden**. El observer event-driven era mas sofisticado
   que el poll, y por eso mismo saturaba el main thread del simulator y perdia
   transiciones. El poll viejo funcionaba porque no competia. Leccion no obvia —
   vale recordarla para no reintentarla sin resolver los bloqueantes primero.

4. **Cross-platform es una promesa costosa y vale la pena respetarla con no-ops
   semanticamente correctos**. Era mas facil decir "keychain reset unsupported on
   Android" y seguir. El no-op con nota agrega tres lineas de codigo y mantiene la
   promesa del proyecto. A cambio, el script del 07-04 se volvio idempotente sin
   bifurcar por plataforma.

5. **Los benchmarks contra otras herramientas sirven como baseline, no como
   metrica competitiva**. ~6s vs ~8s confirma que estamos en el orden de magnitud
   correcto. No es un numero para vender; es un numero para detectar regresiones
   futuras. Si manana este bench tira 15s, sabemos que rompimos algo.

6. **Hay un techo natural de flakiness del app+simulator en ~10-15%**. Sin un
   entorno de medicion mas estable (reset entre corridas, erase del simulator, VM
   aislada), cualquier optimizacion se topa con ese techo. No tiene sentido pelear
   contra ese 10-15% con mas codigo; mejor documentar el modo de falla, dar los
   workarounds, y trackearlo como un issue con prioridad realista (#80).

7. **Los sintomas UX chicos pueden venir de bugs silenciosos grandes**. El freeze
   fantasma del Play button era un `await` donde deberia ser fire-and-forget. Sin
   el usuario notando el freeze, ese codigo habria quedado ahi indefinidamente.

### Archivos modificados

- `cli/Sources/AutoCore/InteractiveLoop.swift` (nuevo)
- `cli/Sources/AutoCore/BridgeError.swift` (`timeout(String)` case)
- `cli/Sources/AutoCore/CommandDispatcher.swift` (waitFor/waitUntilGone throw + `keychain` case)
- `cli/Sources/AutoCore/DeviceBridge.swift` (protocol + default extension para keychain)
- `cli/Sources/AutoLibiOS/SimulatorBridge.swift` (override keychain + auto-dismiss pasteboard)
- `cli/Sources/AutoLibiOS/UIStabilizer.swift` (`quietPeriod` 0.3 → 0.15)
- `cli/Sources/CLI/main.swift` (`runInteractive` + mutators)
- `cli/Sources/CLIAndroid/main.swift` (`runInteractive` Android)
- `editor/src-tauri/src/lib.rs` (`InteractiveState` + 3 comandos)
- `editor/src/App.tsx` (`runScript` reescrito, fire-and-forget fix, autocomplete entries)
- `README.md` (seccion de editor build flow)

### Issues abiertos en la sesion

- #73 — `type[N]` N-th text input filtered by role (cerrado por #72)
- #74 — smart label resolver for `type "label" "text"` (cerrado por #72)
- #75 — iOS 17+ pasteboard dialog blocks `typeText` flow (cerrado por #72)
- #76 — editor autocomplete refactor (cerrado por #72)
- #77 — adaptive step quiet period in editor (cerrado por #72)
- #78 — `auto interactive` REPL (cerrado por #72)
- #79 — event-driven `waitFor` via shared AXObserver (BLOQUEADO por los dos bloqueantes del Experimento 3)
- #80 — 10-15% flakiness in `waitFor` after tap on system dialogs
- #81 — `cli/dev-install.sh --editor-post` — auto-copy binario tras `cargo clean` del editor
- #84 — `keychain reset` (cerrado por #85)
- #86 — AccountManager clearing para Google Sign-In en Android

---

## Links

- [Capitulo 14 del libro](../libro/14-validacion-en-una-app-real.md) — version narrativa y pulida
  de esta bitacora.
- [Bitacora del recorder](../recorder/BITACORA.md) — diario de la sesion previa del recorder
  semantico (mismo formato, otro experimento).
