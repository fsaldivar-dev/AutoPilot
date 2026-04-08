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
8. ["Unknown command: interactive" al apretar Play en el editor](#editor-unknown-interactive)
9. [El editor muestra "0ms" pero el boton Play queda muerto ~500ms](#editor-play-freeze)
10. [`waitFor` funciona la primera vez, despues falla en scripts de login iOS](#waitfor-keychain)
11. [`waitFor` timeout aunque el elemento aparecio un momento](#waitfor-flakiness)
12. [Editor se queda con binarios stale despues de `cargo clean`](#editor-cargo-clean)

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

## 8. "Unknown command: interactive" al apretar Play en el editor <a id="editor-unknown-interactive"></a>

**Sintoma:** Sobre una maquina limpia, despues de clonar el repo y correr `npm run tauri build` en `editor/`, al abrir el `.app` resultante y apretar Play en un script cualquiera el panel de output muestra:

```
--- sidecar Unknown command: interactive ---
ERROR: write: Broken pipe (os error 32)
```

El boton Play queda deshabilitado y ningun step se ejecuta.

**Diagnostico:** A partir del commit `fecf578` (PR #72), el editor dejo de hacer spawn de `auto <step>` por comando y paso a usar un sidecar persistente via `auto interactive` / `auto-android interactive`. Tauri bundlea el binario desde `editor/src-tauri/binaries/auto-<target-triple>`, pero ese directorio esta en `.gitignore`: sobre un clone limpio solo tiene el `.gitignore` y ningun binario. `npm run tauri build` no falla — empaqueta lo que encuentre, que puede ser nada o un `auto` stale si el usuario tenia una copia vieja por ahi. El `.app` resultante spawnea ese binario viejo, que no conoce el comando `interactive`, y tira el error literal del CLI.

Reproduccion minima:

```
$ git clone <repo> fresh
$ cd fresh/editor
$ npm install
$ npm run tauri build
$ open src-tauri/target/release/bundle/macos/AutoPilot.app
# apretar Play en un ping → "Unknown command: interactive"
```

**Workaround validado:** Correr el script de setup del editor **antes** del primer `tauri build`. Esto compila el CLI en release y copia ambos binarios (`auto`, `auto-android`) a los dos lugares que Tauri necesita (`target/debug/` y `binaries/<target-triple>`):

```bash
# primera vez en la maquina
cd editor
./setup.sh
npm run tauri build
```

Si ya cambiaste algo en `cli/Sources/...` y necesitas refrescar el bundle:

```bash
cd cli && swift build && cd ..
./editor/refresh-binaries.sh
cd editor && npm run tauri build
```

La documentacion oficial del flow esta en la seccion "Editor visual (Tauri + Monaco)" del README, agregada por PR #82 (commit `4e60ba4`) despues de que este bug apareciera exactamente asi en maquina limpia.

**Estado:** Limitacion conocida con workaround documentado. Fix permanente tracked en [#81](https://github.com/fsaldivar-dev/AutoPilot/issues/81): hook automatico post-build de `cargo` que sincronice los binarios del CLI sin requerir el script manual.

---

## 9. El editor muestra "0ms" pero el boton Play queda muerto ~500ms <a id="editor-play-freeze"></a>

**Sintoma:** Un script de un solo `ping` muestra casi inmediato `Simulator found (0ms)` y `1 step(s) completed` en el panel de output, pero el boton Play del editor no vuelve a habilitarse por otro medio segundo. El usuario percibe "el step corrio en 0ms pero se siente lento" y no hay feedback visual que explique el gap.

**Diagnostico:** En `editor/src/App.tsx` la funcion `runScript` tenia este bloque al final:

```typescript
appendOutput(`\n${stepNum} step(s) completed`);
setCurrentStep(-1);
try { await refreshTree({ silent: true }); } catch {}
setRunning(false);
```

El `await refreshTree({ silent: true })` dispara un tree dump + screenshot + reconstruccion del element index, que en una app razonable tarda entre 300ms y 800ms. Durante ese `await` el estado `running` sigue en `true`, asi que el boton Play sigue deshabilitado aunque el step ya termino y el usuario ya vio el mensaje de "completed". Como el refresh es silencioso (`silent: true`), tampoco hay mensajes intermedios en el output — es un freeze sin rastro.

Medicion con el bench de un solo step (`ping`) sobre `fecf578`:

- Tiempo que tarda el ping: ~40-60ms (sidecar warm) o ~100ms (cold start)
- Tiempo entre "completed" y Play habilitado de nuevo: ~500ms promedio sobre la app de prueba
- Gap observable: ~450ms en los que la UI esta "como congelada"

**Workaround validado:** reordenar el bloque para llamar `setRunning(false)` inmediatamente despues del output de "completed", y lanzar el `refreshTree` como fire-and-forget. El autocomplete se actualiza en background mientras el Play ya esta disponible:

```typescript
appendOutput(`\n${stepNum} step(s) completed`);
setCurrentStep(-1);
setRunning(false);
refreshTree({ silent: true }).catch(() => {});
```

Con este patch el Play button queda disponible en ~60ms despues del "completed", consistente con el overhead real del sidecar. El refresh del tree sigue pasando pero ya no bloquea la UI.

**Estado:** Fix en PR #83 (commit `00a1dbf`), OPEN MERGEABLE a la hora de escribir esta entrada. Regla general: cualquier `await` silencioso post-script va como fire-and-forget. Si alguien agrega un nuevo refresh silencioso en el futuro, tiene que seguir el mismo patron.

---

## 10. `waitFor` funciona la primera vez, despues falla en scripts de login iOS <a id="waitfor-keychain"></a>

**Sintoma:** Un script `.auto` que automatiza un login desde cero (`uninstall → install → launch → waitFor "Iniciar sesion" → tap → type → ...`) pasa la primera vez que se corre, pero en la segunda y tercera corrida falla en el primer `waitFor` con:

```
Error: Timeout: 'Iniciar sesion' not found after 10.0s
```

Al tomar un screenshot justo antes del timeout se ve que la app ya esta en una pantalla post-login tipo "Hola, Maria" o directamente en el home — el flujo de "primer uso" nunca aparece, el script intenta tappear un boton que nunca se muestra.

**Diagnostico:** Esta es la misma clase de bug que el [#3](#uninstall-no-limpio), escalada al caso en el que ya existe un usuario logueado en la iteracion anterior. En iOS el keychain compartido pertenece al **device**, no al bundle — `xcrun simctl uninstall` + `install` no limpia el keychain. El siguiente `launch` lee las credenciales guardadas, skippea el screen de login y entra directo a la home. Desde el punto de vista del script, `waitFor "Iniciar sesion" 10` hace exactamente lo que tiene que hacer: esperar un elemento que no existe y timeout-ear.

Reproduccion sobre una app bancaria de prueba, tres iteraciones seguidas del mismo script:

```
$ auto run login.auto  # run 1
ping → ok
uninstall → ok
install → ok
launch → ok
waitFor "Iniciar sesion" → found in 2.1s
... resto del script pasa ...

$ auto run login.auto  # run 2
ping → ok
uninstall → ok
install → ok
launch → ok
waitFor "Iniciar sesion" → Timeout: 'Iniciar sesion' not found after 10.0s
```

**Workaround validado:** Agregar `keychain reset` entre `uninstall` e `install`. El comando fue introducido en PR #85 (commits `d121565` + `860c770`) justamente para este caso:

```auto
uninstall com.example.app
keychain reset
install /path/to/App.app
launch com.example.app
waitFor "Iniciar sesion" 10
```

En iOS esto llama `xcrun simctl keychain <udid> reset`, un wipe device-wide del keychain compartido del Simulador (465ms en el smoke test). En Android el mismo comando es un **no-op con nota impresa**, porque el Android Keystore es per-app (tied a la UID del proceso) y `pm uninstall` ya libera esas keys cuando desinstala la app:

```
$ auto-android keychain reset
Keychain reset: no-op on this platform (Android Keystore is per-app, already cleared by uninstall)
Keychain reset (0ms)
```

El mismo script `.auto` corre bien en ambas plataformas sin ramas condicionales. Ese fue el motivo explicito de diseñar el comando como no-op en Android en lugar de tirar "unsupported on this platform" — la promesa del proyecto es que el mismo script funciona en iOS y Android cambiando solo el binario.

**Edge case conocido (no resuelto aun):** Apps con Google Sign-In via `AccountManager` de Android guardan accounts device-wide que **sobreviven** el `uninstall`. El `keychain reset` no las toca. Workaround temporal: `clearState com.google.android.gms` (nuclear, resetea todos los servicios de Google del emulador). Tracked en [#86](https://github.com/fsaldivar-dev/AutoPilot/issues/86) como follow-up con tres niveles propuestos (alias de `keychain reset`, `accounts remove` quirurgico, Credential Manager API 34+).

**Estado:** Fix en PR #85, OPEN MERGEABLE. Ver tambien [Capitulo 14](../14-validacion-en-una-app-real.md) y el [BITACORA de validacion](../../validacion/BITACORA.md) para el diario crudo del descubrimiento.

---

## 11. `waitFor` timeout aunque el elemento aparecio un momento <a id="waitfor-flakiness"></a>

**Sintoma:** En scripts de login sobre una app comercial real, `waitFor "Argentina" 10` termina con timeout, pero inmediatamente despues el `waitFor "No permitir" 10` del step siguiente encuentra el dialogo de permisos en ~100ms. Queda claro que la app paso por "Argentina" (de hecho ya avanzo al dialogo del sistema), pero el polling de `waitFor` no llego a verlo. No es deterministico: en una de cada seis u ocho corridas contra la misma app, con el mismo script, falla en un `waitFor` distinto y al siguiente step ya esta todo adelantado.

**Diagnostico:** Hay ~10-15% de flakiness inherente en `waitFor` despues de un `tap` sobre system dialogs, medida sobre el codigo estable `fecf578` (sin ningun experimento de observer hybrid encima — ver el post-mortem en la memoria del proyecto). Los modos de falla observados en 9 corridas del bench de login sobre una app comercial real:

1. `Timeout: 'Argentina' not found after 10.0s` pero el subsiguiente `waitFor 'No permitir'` lo encuentra inmediato.
2. `Timeout: 'No permitir' not found after 10.0s` despues de un `tap 'Argentina'` que retorno ok.

Causas sospechadas (no diagnosticadas definitivamente):

- El `CGEventPost` del `tap` reporta exito pero el evento cae en un pixel que esta fuera del hit-test frame del target (race con una animacion de layout).
- Race entre el tap retornando y el siguiente view controller construyendo su view hierarchy — el polling arranca antes de que el nuevo screen se haya registrado en el AX tree.
- State acumulado del Simulator tras N iteraciones de install/uninstall/launch en la misma sesion del bench.
- Transiciones muy breves (un picker de pais que aparece <200ms y se cierra solo) que el poll de 500ms literalmente se pierde entre un check y el siguiente.

**Workarounds conocidos** (en orden de invasividad creciente):

1. **Agregar `wait 0.5` entre el `tap` y el siguiente `waitFor`.** Le da aire al Simulator para renderizar el siguiente screen antes de empezar a polear. Es el workaround mas barato y cubre la mayoria de los casos.

   ```auto
   tap "Argentina"
   wait 0.5
   waitFor "No permitir" 10
   ```

2. **Reboot del Simulator entre runs del bench.** Si estas corriendo el mismo script en loop para medir, reiniciar el booted device entre iteraciones reduce el state acumulado:

   ```bash
   xcrun simctl shutdown booted && xcrun simctl boot <udid>
   ```

3. **Nuclear: `xcrun simctl erase booted`.** Borra todo el state del device (no solo la app). Ultimo recurso para runs de diagnostico.

**Lo que NO funciono:** durante la sesion 2026-04-08 se intento reemplazar el poll de 500ms de `waitFor` por un hybrid observer+poll (AXObserver despertando el check en cada evento AX). El pass rate cayo a 3/6 (50%) porque el tree dump en cada evento contendia con la inicializacion interna del Simulator. Revertido limpio, detalle completo en la memoria `feedback_observer_hybrid.md` del proyecto. Leccion meta: el poll de 500ms "funcionaba por accidente" porque su lentitud le daba aire al Simulator para renderizar.

**Estado:** Limitacion conocida, tracked en [#80](https://github.com/fsaldivar-dev/AutoPilot/issues/80). Los bloqueantes para un retry del observer hybrid estan listados en [#79](https://github.com/fsaldivar-dev/AutoPilot/issues/79): (1) necesitar una query AX ~5ms en lugar del tree dump de 30-50ms, (2) debounce agresivo del observer para no oversamplear con bursts de 20-30 eventos/s durante el app init.

---

## 12. Editor se queda con binarios stale despues de `cargo clean` <a id="editor-cargo-clean"></a>

**Sintoma:** Despues de correr `cargo clean` en `editor/src-tauri` (tipicamente porque un rebuild fallo raro y uno quiere empezar de cero), al volver a correr `npm run tauri dev` el editor arranca pero el comportamiento del sidecar no matchea lo que esta en `cli/Sources/...`. A veces el Play tira errores de comandos que no deberian existir, a veces corre una version anterior que ya no tiene un fix que se commiteo localmente.

**Diagnostico:** `cargo clean` borra `editor/src-tauri/target/` entero, incluyendo cualquier `auto` o `auto-android` que se haya copiado ahi manualmente. Cargo no conoce esos binarios — son artefactos Swift, externos al crate — asi que no los rebuilds, no los restaura, ni los trackea como dependencies. Al proximo `tauri dev`, Tauri busca el binario y o no lo encuentra (y el editor falla mas ruidosamente), o pica un candidato stale de otra ubicacion del sistema PATH que no es el de la workspace.

Reproduccion minima:

```
$ cd editor/src-tauri
$ ls target/debug/auto*
target/debug/auto          target/debug/auto-android

$ cargo clean
$ ls target/debug/auto* 2>&1
ls: target/debug/auto*: No such file or directory

$ cd ../.. && cd editor && npm run tauri dev
# → el editor arranca pero el sidecar corre un binario que no es el actual
```

**Workaround validado:** Despues de cada `cargo clean`, copiar los binarios del CLI manualmente antes de volver a arrancar el editor:

```bash
cp cli/.build/debug/auto editor/src-tauri/target/debug/auto
cp cli/.build/debug/auto-android editor/src-tauri/target/debug/auto-android
```

O, mas prolijo, correr el helper que hace exactamente esto ademas de actualizar el directorio `binaries/`:

```bash
./editor/refresh-binaries.sh
```

Si el CLI tampoco esta compilado, primero:

```bash
cd cli && swift build && cd ..
./editor/refresh-binaries.sh
```

**Estado:** Limitacion conocida con workaround. Fix permanente propuesto en [#81](https://github.com/fsaldivar-dev/AutoPilot/issues/81): hook post-build de `cargo` (via `build.rs` o script del workspace) que sincronice automaticamente los binarios del CLI en `target/debug/` y `target/release/` despues de cada compilacion, sin requerir el refresh manual. Related: este mismo problema en su variante "maquina limpia primera vez" es el problema [#8](#editor-unknown-interactive).

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
