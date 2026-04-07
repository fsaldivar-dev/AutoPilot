# Apendice D — Troubleshooting

Problemas comunes al escribir y ejecutar scripts `.auto`, con sus causas y workarounds. Las entradas que estan aca salieron de sesiones reales de automatizacion: cada una incluye sintoma, diagnostico con outputs literales del CLI, workaround validado y estado actual.

Si encontras un bug nuevo o un patron que no esta aca, agregalo siguiendo el mismo formato. La idea de este apendice es que sea un cuaderno de bitacora vivo, no una referencia estatica.

---

## Indice

1. [hideKeyboard reporta dismissed pero el teclado sigue visible (Android)](#hidekeyboard-android)
2. [scrollTo retorna "Invalid direction" (Android)](#scrollto-direction)
3. [`auto uninstall` + `install` no deja la app en estado limpio (iOS)](#uninstall-no-limpio)
4. [Dialogos del sistema iOS no aparecen en `auto tree`](#dialogos-sistema-ios)
5. ["Element not found" en Compose Android tras tipear](#compose-lazy-tree)
6. [`pressKey back` es Android-only y no esta en la doc principal](#presskey-back)
7. [Las credenciales en scripts `.auto` colisionan con secret scanners](#secrets-en-scripts)

---

## 1. hideKeyboard Android no funciona <a id="hidekeyboard-android"></a>

**Sintoma:** Despues de un `tap` en un campo password seguido de `type` y `hideKeyboard`, el teclado virtual sigue visible en pantalla. El boton submit del formulario queda tapado por el teclado y los siguientes comandos del script fallan.

**Diagnostico:** El comando reporta exito pero no produce ningun efecto sobre el teclado. Reproduccion minima sobre una app de prueba con un formulario de login:

```
$ auto-android tap "pswd_input"
Tapped 'pswd_input' (412ms)

$ auto-android type "Passw0rd!"
Typed 'Passw0rd!' (831ms)

$ auto-android hideKeyboard
Keyboard dismissed (67ms)

$ auto-android screenshot /tmp/after-hide.png
Saved screenshot to /tmp/after-hide.png
```

El exit code es `0` y el mensaje del CLI dice `Keyboard dismissed`, pero al abrir el screenshot el teclado sigue cubriendo la mitad inferior de la pantalla. Como en Compose el AX tree es **lazy** (solo expone elementos que estan dentro del viewport visible), el siguiente intento de buscar el boton submit retorna vacio:

```
$ auto-android tree -s "login_button"
(no output)

$ auto-android tap "login_button"
Error: Element not found: login_button
```

**Workaround validado:** Usar `pressKey back` en lugar de `hideKeyboard`. Internamente esto manda un `KEYCODE_BACK` al device, que es la unica forma confiable de cerrar el IME en Android desde fuera de la app:

```
$ auto-android pressKey back
Pressed key 'back' (52ms)
```

Importante: hay que esperar al menos 2 segundos despues del `pressKey back` antes de buscar el boton submit. Compose necesita un par de frames para reposicionar el formulario una vez que el teclado se cierra; si lo intentas inmediatamente, `tree -s` todavia retorna vacio porque el botton no esta en el viewport renderizado:

```bash
type "Passw0rd!"
pressKey back
wait 2
waitFor "login_button" 5
tap "login_button"
```

**Estado:** Bug abierto. El comando `hideKeyboard` esta intentando una via que no funciona en el device real (probablemente `dismissDropDown` del UiAutomator, que no afecta al IME). Hasta que se arregle, `pressKey back` es la forma canonica de cerrar el teclado en Android.

---

## 2. `scrollTo` retorna "Invalid direction" <a id="scrollto-direction"></a>

**Sintoma:** Cualquier llamada a `scrollTo` en Android termina con error y exit code distinto de cero, incluso cuando se le pasa una direccion explicita.

**Diagnostico:** Tanto la forma corta como la forma con direccion explicita fallan:

```
$ auto-android scrollTo "login_button"
Error: ADB failed: Invalid direction: . Use up/down/left/right

$ auto-android scrollTo "login_button" down
Error: ADB failed: Invalid direction: . Use up/down/left/right
```

El mensaje de error es revelador: el CLI dice `Invalid direction: ` con un string vacio donde deberia ir `down`, `up`, etc. Esto sugiere que el dispatcher Android no esta parseando bien el segundo argumento (el target) y termina pasando string vacio al parametro de direccion.

**Workaround validado:** Como `scrollTo` esta roto, hay dos alternativas que funcionan en los flujos donde se necesitaba scrollear hasta un elemento:

1. **Cerrar el teclado primero con `pressKey back`** — En la mayoria de los casos donde `scrollTo` aparecia, el problema real era que el boton estaba debajo del teclado abierto. Cerrandolo, el boton vuelve al viewport y `tap` lo encuentra sin necesidad de scroll.

2. **Usar `swipe up` o `scroll <container> down`** — Si el boton genuinamente esta debajo del fold, un `swipe up` global o un `scroll` con un container de referencia logran el mismo efecto:

   ```bash
   swipe up
   waitFor "login_button" 3
   tap "login_button"
   ```

**Estado:** Bug abierto, no bloqueante. El comando deberia ser arreglado en el dispatcher Android (CommandDispatcher.swift). Mientras tanto, los workarounds cubren todos los casos reales que vimos.

---

## 3. `auto uninstall` + `install` no deja la app en estado limpio (iOS) <a id="uninstall-no-limpio"></a>

**Sintoma:** Tras desinstalar e instalar una app comercial, la primera ejecucion no presenta el flujo de "primer uso" — la app recuerda al ultimo usuario logueado y muestra una pantalla intermedia tipo "Hola, Maria". El formulario de login completo (que es lo que queriamos automatizar desde cero) no aparece.

**Diagnostico:** La secuencia esperada:

```
$ auto uninstall com.example.app
Uninstalled com.example.app

$ auto install /path/to/App.app
Installed /path/to/App.app

$ auto launch com.example.app
Launched com.example.app
```

A simple vista todo correcto. Pero al revisar el screenshot post-launch, la app salta directamente a un estado intermedio en lugar de la pantalla de onboarding. Causa raiz: en iOS, las credenciales de la app se guardan en el **shared keychain por bundle id**, y el keychain del Simulador **no se borra** cuando se desinstala el `.app`. El proximo `install` instala los binarios pero el keychain del bundle todavia tiene las entradas del usuario anterior, asi que la app las lee al arrancar.

`auto clearState` tampoco resuelve esto — borra los datos del Application Support de la app pero no toca el keychain compartido.

**Workaround validado:** Dentro del flujo de la app suele haber una opcion tipo "No soy yo" o "Cambiar usuario" que limpia el state visible y lleva al formulario completo. Es especifico de cada app y hay que descubrirlo navegando manualmente la primera vez:

```bash
launch com.example.app
waitFor "Hola" 10
tap "No soy yo"
waitFor "Iniciar sesion" 10
# ahora si, formulario completo
```

**Fix propuesto (futuro):** Que `auto clearState <bundleId>` tambien elimine las entradas del keychain del bundle (via `security delete-generic-password` o equivalente sobre el keychain del Simulador). Eso convertiria a `clearState` en una verdadera operacion de "factory reset" para una app individual, sin necesidad de uninstall + reinstall.

**Estado:** Limitacion conocida. Documentar como gotcha hasta que el fix de `clearState` este implementado.

---

## 4. Dialogos del sistema iOS no aparecen en `auto tree` <a id="dialogos-sistema-ios"></a>

**Sintoma:** Despues de hacer submit de credenciales en una app, iOS muestra un dialogo modal del sistema "¿Guardar contrasena?" con botones "Ahora no" / "Guardar". El dialogo bloquea la app, pero `auto tree` muestra el AXGroup principal vacio y ningun comando del CLI puede interactuar con los botones.

**Diagnostico:** Reproduccion sobre un Simulador iOS justo despues de un submit de login en una app comercial:

```
$ auto tree
(arbol vacio: AXGroup -> AXChildren=[0])

$ auto tree -s "Ahora no"
No elements found

$ auto exists "Ahora no"
NO

$ auto pressKey escape
(sin efecto)

$ auto pressKey enter
(sin efecto)

$ auto pressKey tab
(sin efecto)
```

Causa raiz: el dialogo "Guardar contrasena" no es parte del proceso de la app — vive en otro proceso del sistema (probablemente `passd` o el subsistema de Password AutoFill) y se renderiza por encima del Simulator window. La AX API que usa `auto` solo ve los procesos hijos del Simulator, no los dialogos del sistema host. Por eso el AX tree esta literalmente vacio mientras el dialogo esta activo.

**Workaround validado:** Forzar terminate + relaunch de la app inmediatamente despues del submit. La app recuerda al usuario en el keychain (por la limitacion #3) y el segundo launch entra directo a la pantalla post-login sin volver a disparar el dialogo de guardar contrasena:

```bash
tap "Iniciar sesion"
wait 1
terminate com.example.app
wait 1
launch com.example.app
waitFor "Inicio" 15
```

Esto es contraintuitivo (matar la app justo despues de haberla logueado se siente como un retroceso) pero es la unica forma de saltear el dialogo modal del sistema sin intervencion humana.

**Estado:** Limitacion arquitectonica. No es practico arreglarla porque implicaria hookear procesos del sistema host. Documentar como gotcha de iOS.

---

## 5. "Element not found" en Compose Android tras tipear <a id="compose-lazy-tree"></a>

**Sintoma:** En una app Android construida con Jetpack Compose, despues de tipear texto en un campo, los siguientes intentos de buscar elementos del mismo formulario fallan con "Element not found", aun cuando esos elementos estaban visibles antes del `type`.

**Diagnostico:** Compose renderiza la UI de forma **lazy**: el AX tree expuesto via UiAutomation solo contiene los elementos que estan **actualmente visibles en el viewport**. Si un elemento esta debajo del fold (porque el formulario es alto, porque el teclado lo tapo, o porque hay un ScrollView por encima), simplemente no existe en el arbol que `auto-android tree` puede consultar.

Reproduccion tipica:

```
$ auto-android tree -s "login_button"
[login_button] Iniciar sesion (visible: true)

$ auto-android tap "pswd_input"
Tapped 'pswd_input' (398ms)

$ auto-android type "Passw0rd!"
Typed 'Passw0rd!' (812ms)
# en este punto el teclado abierto cubre el boton login

$ auto-android tree -s "login_button"
(no output: el boton ya no esta en el viewport)

$ auto-android tap "login_button"
Error: Element not found: login_button
```

**Workaround validado:** Cerrar el teclado con `pressKey back` y esperar 2 segundos para que Compose recomponga el formulario antes de buscar el boton:

```bash
type "Passw0rd!"
pressKey back
wait 2
waitFor "login_button" 5
tap "login_button"
```

Si el boton todavia esta debajo del fold despues de cerrar el teclado (formularios muy largos), agregar un `swipe up` o un `scroll <container> down` para traerlo al viewport. Cuidado: `scrollTo` esta bugueado, ver [problema #2](#scrollto-direction).

**Por que pasa esto:** Es una propiedad fundamental del Compose. A diferencia de los layouts XML de Android (que mantienen toda la jerarquia en memoria aunque no este visible), Compose solo materializa los nodos del UI tree que estan dentro del area renderizable. El bridge de UiAutomation no puede inventar nodos que no existen.

**Estado:** No es un bug, es como funciona Compose. La leccion practica es que **siempre que tipees en un campo, despues de tipear cerra el teclado y espera**, sino los siguientes pasos del script van a ser fragiles.

---

## 6. `pressKey back` es Android-only y critico para cerrar el teclado <a id="presskey-back"></a>

**Sintoma:** Un script escrito para iOS usa `pressKey back` y al portarlo a Android funciona, pero al revertirlo a iOS falla con un error sobre tecla invalida.

**Diagnostico:** `pressKey` acepta diferentes claves segun la plataforma. La tecla `back` solo existe en Android (mapea al `KEYCODE_BACK` del sistema operativo) y es la forma canonica de cerrar el IME, abandonar dialogos modales, y volver a la pantalla anterior en la pila de actividades. iOS no tiene un equivalente directo porque su modelo de navegacion es diferente.

Las teclas validas por plataforma son:

| Plataforma | Teclas validas |
|---|---|
| iOS | `home`, `enter`, `delete`, `tab`, `escape`, `volumeUp`, `volumeDown` |
| Android | `home`, `back`, `enter`, `delete`, `volumeUp`, `volumeDown`, `power` |

`back` y `power` son **Android-only**. `tab` y `escape` son **iOS-only**.

**Workaround validado:** Si necesitas un script cross-platform que cierre el teclado, no podes usar `pressKey back` porque rompe en iOS. La mejor opcion es separar el flujo en dos scripts (uno por plataforma) o usar el comando que cada plataforma soporta nativamente. En la practica, los flujos de login son lo suficientemente distintos entre iOS y Android que mantener dos `.auto` separados no agrega tanto overhead.

**Estado:** No es un bug, es una diferencia legitima entre plataformas. La documentacion del comando `pressKey` en `comandos.md` ahora lista las teclas validas por plataforma para evitar confusion.

---

## 7. Las credenciales en scripts `.auto` colisionan con secret scanners <a id="secrets-en-scripts"></a>

**Sintoma:** Un script `.auto` que automatiza un login necesita la contrasena del usuario hardcodeada. Al commitear el script al repositorio, los pre-commit hooks de secret-detection (gitleaks, trufflehog, etc.) bloquean el commit porque detectan una credencial en texto plano.

**Diagnostico:** El parser de `.auto` tokeniza pero **no expande variables de entorno**. Si escribis:

```bash
type "$EMAIL"
type "$PASSWORD"
```

el comando `type` recibe literalmente los strings `$EMAIL` y `$PASSWORD`, no los valores de las variables del shell. La unica forma de pasar credenciales reales por el script es hardcodearlas:

```bash
type "user@example.com"
type "MiContrasenaSecreta123!"
```

Esto colisiona con cualquier politica de seguridad razonable: el script no puede vivir en el repo con valores reales, pero tampoco se puede parametrizar.

**Workaround actual:** En lugar de correr el script con `auto run`, ejecutar los comandos uno por uno desde la shell, donde las variables de entorno SI funcionan:

```bash
export EMAIL="user@example.com"
export PASSWORD="MiContrasenaSecreta123!"

auto launch com.example.app
auto waitFor "Email" 10
auto type "Email" "$EMAIL"
auto type "Password" "$PASSWORD"
auto tap "Iniciar sesion"
```

Esto pierde la ventaja de tener un script `.auto` versionado, pero al menos no expone credenciales en el repo.

**Fix propuesto (futuro, P0):** Que `ScriptParser.swift` haga expansion de `$VAR` y `${VAR}` antes de tokenizar. Esto seria un cambio chico (~20 lineas) pero abriria la puerta a tener scripts `.auto` parametrizables y seguros para versionar.

**Estado:** Limitacion conocida del parser. Es una de las primeras prioridades del backlog porque impacta directamente cualquier flujo que necesite credenciales reales.

---

## Como agregar una entrada nueva a este apendice

Cuando descubras un bug o limitacion durante una sesion de automatizacion, agregalo aca con el siguiente formato:

1. **Sintoma** — Una descripcion en una o dos lineas de lo que ves desde fuera.
2. **Diagnostico** — Reproduccion minima con outputs literales del CLI (copiar y pegar la salida real, no parafrasear).
3. **Workaround validado** — Lo que efectivamente resolvio el problema en la practica.
4. **Estado** — `Bug abierto` / `Limitacion conocida` / `Fix propuesto` / `No es bug, es asi por diseno`.
5. **Link relacionado** — Si el descubrimiento vino de una sesion documentada en un capitulo o bitacora, linkearlo.

La idea es que este apendice acumule conocimiento de campo: cada sesion deja al menos una entrada si encontro algo que no estaba documentado. Despues de un par de meses, este archivo deberia ser el primer lugar al que vas cuando algo falla de forma no obvia.

---

**Ver tambien:**
- [Apendice A — Referencia de comandos](comandos.md) para la sintaxis completa de cada comando.
- [Apendice B — Guia de scripts .auto](scripts.md) para los patrones recomendados que evitan estos problemas en primer lugar.
- [Apendice C — Variables de entorno](variables-entorno.md) para configuracion del CLI y CI.
