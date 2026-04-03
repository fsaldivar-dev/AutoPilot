# Apendice A — Referencia de Comandos

AutoPilot expone dos binarios: `auto` (iOS) y `auto-android` (Android). Ambos comparten la mayoria de comandos a traves de `CommandDispatcher`, un dispatcher central que recibe cualquier `DeviceBridge` y ejecuta la misma logica. Los comandos que dependen de APIs de plataforma (AXUIElement en iOS, adb/agente en Android) viven en sus respectivos `main.swift`.

La regla es simple: si el comando funciona igual en ambas plataformas, esta en el dispatcher compartido. Si necesita algo especifico del dispositivo, esta en el binario correspondiente.

---

## Conexion

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `ping` | `auto ping` | iOS | Verifica que Simulator.app esta corriendo y accesible via AX | `auto ping` |
| `ping` | `auto-android ping` | Android | Verifica conexion ADB y devuelve el device ID | `auto-android ping` |
| `list` | `auto list` | Ambas | Lista dispositivos disponibles (booted y shutdown) con nombre, OS y UDID | `auto list` |

## Arbol y busqueda

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `tree` | `auto tree` | Ambas | Imprime el arbol de accesibilidad completo del dispositivo activo | `auto tree` |
| `tree -s` | `auto tree -s "query"` | Ambas | Busca elementos en el arbol que coincidan con el query | `auto tree -s "Login"` |
| `index` | `auto index [query]` | iOS | Construye un indice numerico de todos los elementos. Permite buscar y despues hacer tap por `$N` | `auto index "Camera"` |
| `exists` | `auto exists <label>` | Ambas | Verifica si un elemento existe en el arbol. Imprime YES o NO | `auto exists "Submit"` |
| `elementAt` | `auto elementAt <x> <y>` | Ambas | Devuelve el elemento en las coordenadas especificadas | `auto elementAt 200 400` |
| `inspect` | `auto inspect <query>` | iOS | Debug profundo: dump de atributos AX del elemento. Util cuando `tree -s` no encuentra algo que deberia estar ahi | `auto inspect "NavigationBar"` |

## Interaccion

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `tap` | `auto tap <label>` | Ambas | Tap en un elemento por identifier, title o label. Soporta multi-tap con comas | `auto tap "Sign In"` |
| `tap` (con indice) | `auto tap $N` | iOS | Tap por indice numerico del `index`. Reconstruye el indice si no existe | `auto tap $5` |
| `tap` (con ocurrencia) | `auto tap Label[N]` | iOS | Tap en la N-esima ocurrencia de un label duplicado | `auto tap Camera[2]` |
| `tap` (multiples) | `auto tap a,b,c` | Ambas | Taps secuenciales en multiples elementos separados por coma | `auto tap 1,2,3,4` |
| `tapAt` | `auto tapAt <x> <y>` | Ambas | Tap en coordenadas absolutas (no busca elemento) | `auto tapAt 150 300` |
| `doubleTap` | `auto doubleTap <label>` | Ambas | Doble tap en un elemento | `auto doubleTap "Image"` |
| `longPress` | `auto longPress <label> [secs]` | Ambas | Presion larga. Default 1 segundo | `auto longPress "Delete" 2` |
| `type` | `auto type <text>` | Ambas | Escribe texto en el campo enfocado | `auto type "user@test.com"` |
| `type` (con target) | `auto type <target> <text>` | Ambas | Hace tap en el target y luego escribe el texto | `auto type "Email" "user@test.com"` |
| `clear` | `auto clear <label>` | Ambas | Limpia el contenido de un campo de texto | `auto clear "Username"` |
| `scroll` | `auto scroll <label> <dir>` | Ambas | Scroll en un elemento. Direcciones: up, down, left, right | `auto scroll "List" down` |
| `swipe` | `auto swipe <dir>` | Ambas | Swipe global. Direcciones: up, down, left, right | `auto swipe up` |
| `waitFor` | `auto waitFor <label> [timeout]` | Ambas | Espera hasta que un elemento aparezca. Polling cada 500ms. Default 10s. Sale con exit(1) si timeout | `auto waitFor "Welcome" 15` |
| `wait` / `sleep` | `auto wait <secs>` | Ambas | Pausa la ejecucion N segundos. Default 1s | `auto wait 2` |

## App

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `launch` | `auto launch <bundleId> [flags]` | iOS | Lanza app. Soporta `--inject <img>` para camera mock, `--env KEY=VALUE`, `--recompile`. Lee config de `.autopilot` si no se pasa bundleId | `auto launch com.example.app --inject foto.jpg` |
| `launch` | `auto-android launch <package>` | Android | Lanza app. Lee bundleId de `.autopilot` si no se pasa | `auto-android launch dev.autopilot.test.Explorea` |
| `terminate` | `auto terminate <bundleId>` | Ambas | Termina (kill) la app | `auto terminate com.example.app` |
| `install` | `auto install <path>` | Ambas | Instala app en el dispositivo (.app en iOS, .apk en Android) | `auto install build/App.app` |

## Dispositivo

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `boot` | `auto boot <name\|udid>` | Ambas | Enciende un dispositivo por nombre o UDID | `auto boot "iPhone 15"` |
| `shutdown` | `auto shutdown <name\|udid>` | Ambas | Apaga un dispositivo | `auto shutdown "iPhone 15"` |
| `openurl` | `auto openurl <url>` | Ambas | Abre una URL en el dispositivo | `auto openurl "https://example.com"` |

## Media y clipboard

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `screenshot` | `auto screenshot [file.png]` | Ambas | Captura screenshot. Default: `screenshot.png` | `auto screenshot result.png` |
| `media` | `auto media <img> [img2 ...]` | Ambas | Inyecta imagenes al dispositivo (Camera Roll en iOS) | `auto media foto1.jpg foto2.jpg` |
| `paste` (write) | `auto paste <text>` | Ambas | Escribe texto en el pasteboard/clipboard del dispositivo | `auto paste "texto copiado"` |
| `paste` (read) | `auto paste` | Ambas* | Lee el contenido del pasteboard. *En Android solo funciona write via ADB | `auto paste` |

> **Nota Android:** La lectura del clipboard no esta soportada via ADB. `auto-android paste` (sin argumentos) puede fallar. Solo la escritura funciona como workaround.

## Biometria

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `biometric enroll` | `auto biometric enroll` | Ambas | Activa Face ID / fingerprint en el dispositivo | `auto biometric enroll` |
| `biometric unenroll` | `auto biometric unenroll` | Ambas | Desactiva biometria | `auto biometric unenroll` |
| `biometric match` | `auto biometric match` | Ambas | Envia una autenticacion biometrica exitosa | `auto biometric match` |
| `biometric fail` | `auto biometric fail` | Ambas | Envia un fallo de autenticacion biometrica | `auto biometric fail` |
| `biometric status` | `auto biometric status` | Ambas | Verifica si la biometria esta enrolled (YES/NO) | `auto biometric status` |

> Alias: `faceid` funciona como sinonimo de `biometric` en ambas plataformas.

## Camera (iOS)

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `camera start` | `auto camera start <img>` | iOS | Inicia el feed virtual de camara con la imagen dada | `auto camera start foto.jpg` |
| `camera feed` | `auto camera feed <img>` | iOS | Actualiza la imagen del feed de camara en caliente | `auto camera feed foto2.jpg` |
| `camera stop` | `auto camera stop` | iOS | Detiene el feed virtual de camara | `auto camera stop` |
| `camera status` | `auto camera status` | iOS | Muestra si la camara virtual esta activa y que imagen usa | `auto camera status` |
| `inject` | `auto inject <img>` | iOS | Cambia la imagen de la camara mock sin relanzar la app | `auto inject nueva-foto.jpg` |

> **Nota:** La camara virtual en Android aun no esta implementada. Ver [Capitulo 3](../03-la-camara-virtual.md) para el contexto tecnico.

## Build (iOS)

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `build` | `auto build` | iOS | Compila con camera mock usando la configuracion de `.autopilot` (project, scheme, device) | `auto build` |
| `build` (explicito) | `auto build <xcodebuild args>` | iOS | Compila pasando argumentos directamente a xcodebuild | `auto build -project App.xcodeproj -scheme App` |

## Configuracion

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `config` | `auto config` | Ambas | Muestra toda la configuracion del archivo `.autopilot` | `auto config` |
| `config` (get) | `auto config <key>` | Ambas | Lee un valor de configuracion | `auto config bundle` |
| `config` (set) | `auto config <key> <value>` | Ambas | Establece un valor de configuracion | `auto config project App.xcodeproj` |

Claves de configuracion comunes: `project`, `scheme`, `bundle`, `device`, `image`.

## Script

| Comando | Sintaxis | Plataforma | Descripcion | Ejemplo |
|---------|----------|------------|-------------|---------|
| `run` | `auto run <script.auto>` | Ambas | Ejecuta un script `.auto` linea por linea. En iOS incluye auto-wait (UIStabilizer) entre pasos | `auto run login-flow.auto` |

---

## Resumen de plataforma

Comandos **solo iOS**: `ping` (via AX), `index`, `tap $N`, `tap Label[N]`, `inspect`, `launch --inject`, `camera *`, `inject`, `build`.

Comandos **solo Android**: `ping` (via ADB), `launch` (simplificado, sin inject).

Comandos **compartidos** (CommandDispatcher): `tree`, `tree -s`, `tap`, `longPress`, `doubleTap`, `clear`, `type`, `scroll`, `swipe`, `screenshot`, `exists`, `elementAt`, `tapAt`, `media`, `paste`, `boot`, `shutdown`, `install`, `list`, `openurl`, `waitFor`, `wait`/`sleep`, `terminate`, `config`, `biometric`/`faceid`.

> El flag `--legacy` en `auto-android` cambia el bridge de `AgentBridge` (socket TCP, rapido) a `AdbLegacyBridge` (adb shell + uiautomator dump, lento). Se usa para benchmarks comparativos. Ver [Capitulo 9](../09-el-agente-android.md).
