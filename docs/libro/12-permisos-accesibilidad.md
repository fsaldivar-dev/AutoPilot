# Capitulo 12 — Permisos de accesibilidad

## El Inspector que dejo de funcionar

El Inspector del editor funcionaba. Hacias click en "Inspect", aparecia el screenshot del Simulador con overlays interactivos, el arbol de elementos, los indices `$N`. Lo documentamos en el [Capitulo 5](05-el-editor.md), lo usamos para escribir scripts, lo mostramos en demos.

Un dia dejo de funcionar. El boton "Inspect" no devolvia nada. Sin error claro, sin screenshot, sin arbol. El CLI seguia funcionando — `./auto tree` desde la terminal mostraba el arbol completo. Pero desde el editor, silencio.

La investigacion revelo tres problemas independientes que se alinearon al mismo tiempo. Pero la raiz de todos era una: no entendiamos como macOS maneja los permisos de accesibilidad.

---

## Como funciona el arbol AX

AutoPilot lee la interfaz del Simulador usando la API de Accesibilidad de macOS (`AXUIElement`). El flujo es:

```
auto tree
  → SimulatorBridge.findSimulatorContent()
    → NSWorkspace.runningApplications (busca com.apple.iphonesimulator)
    → AXUIElementCreateApplication(pid)  ← requiere permiso AX
    → AXUIElementCopyAttributeValue(kAXWindowsAttribute)
    → Recorre hijos recursivamente (maxDepth: 20)
    → Serializa: role, label, id, value, frame
  → TreePrinter.printAX(tree)
```

La linea clave es `AXUIElementCreateApplication(pid)`. Esta llamada crea un handle al arbol de accesibilidad de otro proceso (el Simulador). macOS no permite que cualquier proceso lea la UI de otro — es una medida de seguridad para evitar que malware lea contraseñas o datos personales de otras ventanas.

Para que funcione, el proceso que hace la llamada necesita **permiso de Accesibilidad** en System Settings > Privacy & Security > Accessibility.

---

## El modelo de permisos TCC

macOS usa un sistema llamado TCC (Transparency, Consent, and Control) para gestionar permisos sensibles. Los permisos de Accesibilidad estan controlados por TCC con reglas especificas:

| Tipo de proceso | Se puede agregar a Accessibility? |
|---|---|
| App bundle (.app con Bundle ID) | Si |
| Binario firmado con Team ID | A veces (depende de la version de macOS) |
| Binario sin firmar / ad-hoc | No |

El CLI `auto` es un binario compilado con Swift Package Manager (`swift build`). No tiene `.app` bundle, no tiene `Info.plist`, no tiene `CFBundleIdentifier`, y la firma es ad-hoc (la minima que Swift genera por defecto).

**No se puede agregar a la lista de Accessibility.** macOS simplemente lo ignora.

Esto parece un problema fatal, pero no lo es. La razon por la que siempre funciono es otra.

---

## Herencia de permisos

Cuando un proceso lanza un subprocess, el hijo hereda los permisos TCC del padre. La cadena es:

```
Terminal.app (tiene permiso AX)
  └── cargo (proceso de Tauri dev)
        └── autopilot-editor (proceso Tauri)
              └── auto tree (subprocess)
                    └── AXUIElementCreateApplication() → funciona
```

El binario `auto` nunca necesito permisos propios. Los heredaba de Terminal.app.

Esto explica por que el CLI siempre funciono desde la terminal: Terminal.app ya tenia permisos de Accesibilidad (probablemente otorgados para otro proposito, como un screen reader o un window manager).

---

## Por que dejo de funcionar

### Causa raiz: cambio de terminal

La version original del editor se desarrollo y probo corriendo `npm run tauri dev` desde Terminal.app. Terminal tenia permisos AX. Todo funcionaba.

Cuando se cambio a **Cursor** (o cualquier otro IDE/terminal que no tuviera permisos AX), la cadena de herencia se rompio:

```
Cursor.app (SIN permiso AX)
  └── shell integrado
        └── npm run tauri dev
              └── autopilot-editor
                    └── auto tree
                          └── AXUIElementCreateApplication() → falla silenciosamente
```

`AXUIElementCopyAttributeValue` no lanza una excepcion ni retorna un error descriptivo — simplemente devuelve `nil`. El arbol queda vacio, `findSimulatorContent()` no encuentra ventana con hijos, y despues de 15 reintentos (3 segundos) lanza `BridgeError.noWindow`.

El mensaje "No simulator window found" era tecnico pero engañoso: el Simulador si estaba corriendo, pero el proceso no tenia permiso para ver su arbol AX.

### Causa agravante: binary bundling

El mismo dia que se detecto el problema, se estaba trabajando en empaquetar los binarios dentro del `.app` bundle para distribucion (PR #41). Los cambios en `find_binary()` y la estructura de paths introdujeron dos problemas adicionales:

1. **PATH incompleto**: Los subprocesos lanzados desde Tauri no heredan el PATH completo del shell. Sin `/usr/bin` y `/opt/homebrew/bin`, el CLI no encontraba `xcrun simctl` (necesario para screenshots y device management).

2. **Activacion del Simulador**: `simRunning.activate()` (sin opciones) no es suficiente cuando el proceso que lo llama no es el proceso en primer plano. Desde un subprocess de Tauri, la activacion simple falla y el arbol AX queda inaccesible incluso con permisos.

Tres problemas al mismo tiempo, todos con el mismo sintoma: "el Inspector no funciona".

---

## Los tres fixes

### Fix 1: PATH extendido para subprocesos

`run_cli()` ahora inyecta un PATH extendido explicitamente:

```rust
fn extended_path() -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/".to_string());
    format!(
        "{path}:/usr/bin:/usr/local/bin:/opt/homebrew/bin:{home}/Library/Android/sdk/platform-tools"
    )
}

fn run_cli(bin: &PathBuf, args: &[&str]) -> Result<String, String> {
    Command::new(bin)
        .args(args)
        .env("PATH", extended_path())
        .env("ANDROID_HOME", android_home())
        .output()
        // ...
}
```

Esto garantiza que `xcrun`, `simctl`, `adb`, y otros tools estan disponibles independientemente de como se lance el editor.

### Fix 2: Activacion con `activateIgnoringOtherApps`

```swift
// ANTES
simRunning.activate()

// DESPUES
simRunning.activate(options: .activateIgnoringOtherApps)
```

La opcion `.activateIgnoringOtherApps` fuerza la activacion del Simulador sin importar que otra app tenga el foco. Es necesario cuando el proceso que hace la llamada es un subprocess sin ventana propia.

### Fix 3: Deteccion explicita de permisos

```swift
// Al final de findSimulatorContent(), si los reintentos fallan:
if !AXIsProcessTrusted() {
    throw BridgeError.accessibilityNotTrusted
}
throw BridgeError.noWindow
```

El error `accessibilityNotTrusted` tiene un mensaje claro:

```
Accessibility permission denied.
Grant access in: System Settings > Privacy & Security > Accessibility.
Add Terminal (or the app running this command).
```

La clave del mensaje es "the app running this command" — no el binario `auto`, sino el proceso padre que lo ejecuta.

---

## La solucion para el usuario

No hay que agregar ningun binario a Accessibility. Hay que agregar **la aplicacion que ejecuta el editor**:

| Contexto | Que agregar a Accessibility |
|---|---|
| `tauri dev` desde Terminal.app | Terminal.app |
| `tauri dev` desde Cursor | Cursor.app |
| `tauri dev` desde iTerm2 | iTerm2 |
| `tauri dev` desde VS Code | Visual Studio Code.app |
| `.app` instalado | AutoPilot Editor.app |
| CLI directo (`./auto tree`) | Terminal.app (o el terminal que uses) |

En nuestro caso, el cambio de Terminal.app a Cursor fue lo que rompio el flujo. Al agregar Cursor a la lista de Accessibility, el Inspector volvio a funcionar inmediatamente.

---

## Alternativas investigadas

Investigamos si era posible eliminar la dependencia de permisos AX por completo:

| Alternativa | Sin AX? | Datos semanticos | Velocidad | Viabilidad |
|---|---|---|---|---|
| `AXUIElement` (actual) | No (herencia) | Completos | ~89ms | Ya implementado |
| idb (Meta) — frameworks privados | Si | Buenos | 200-500ms | Alta pero fragil entre Xcode versions |
| XCUITest HTTP server (Maestro) | No (macOS) | Completos | 500ms-2s | Requiere compilacion |
| `simctl io` + OCR/Vision | Si | Solo texto | 2-5s | Sin labels ni identifiers |

La conclusion fue que no hay alternativa practica que elimine la necesidad de permisos AX y mantenga la calidad de datos semanticos. `AXUIElement` con herencia de permisos sigue siendo la mejor opcion — el requisito real es minimo: un solo click en System Settings para el terminal o IDE que uses.

---

## Que aprendimos

1. **Los permisos AX se heredan, no se asignan por binario.** El proceso hijo hereda los permisos TCC del padre. Nunca fue necesario agregar `auto` a Accessibility — solo el proceso raiz de la cadena.

2. **Cambiar de terminal rompe permisos silenciosamente.** No hay warning, no hay error descriptivo. `AXUIElementCopyAttributeValue` simplemente retorna `nil`. El diagnostico requiere saber buscar en System Settings.

3. **Los subprocesos de Tauri no heredan el shell environment.** En desarrollo (`tauri dev`), Tauri corre como subprocess del terminal y hereda variables. Pero las variables que el shell configura via `.zshrc` o `.bash_profile` (como PATH extendido, ANDROID_HOME) no siempre llegan al subprocess del subprocess.

4. **`activate()` vs `activate(options: .activateIgnoringOtherApps)` importa.** Desde un proceso con ventana propia, `activate()` basta. Desde un subprocess sin ventana, la version con opciones es necesaria para que macOS honre la activacion.

5. **El error "no window found" mentia.** La ventana existia — el proceso no tenia permiso para verla. Agregar `AXIsProcessTrusted()` como check explicito elimino horas de debugging futuro.

---

*Anterior: [Capitulo 11 — El benchmark](11-el-benchmark.md)* | *Siguiente: [Capitulo 13 — El recorder semantico](13-el-recorder-semantico.md)*
