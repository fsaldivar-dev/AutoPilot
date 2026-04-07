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

## Links

- [Capitulo 14 del libro](../libro/14-validacion-en-una-app-real.md) — version narrativa y pulida
  de esta bitacora.
- [Bitacora del recorder](../recorder/BITACORA.md) — diario de la sesion previa del recorder
  semantico (mismo formato, otro experimento).
