# Capítulo 5 — El editor

## De CLI a IDE visual

AutoPilot empezo como un binario de terminal. Escribias `auto tap "Login"`, veias el resultado, escribias el siguiente comando. Funcionaba, pero tenia dos problemas:

**No veias lo que pasaba.** Hacias tap en "Login" y el CLI te decia "Tapped 'Login' (89ms)". Pero ¿donde estaba el botón? ¿Qué más habia en pantalla? ¿El tap fue en el elemento correcto? Para saberlo, tenias que cambiar a la ventana del Simulador, verificar visualmente, y volver a la terminal.

**Escribir scripts era a ciegas.** Un script `.auto` es una secuencia de comandos. Pero para escribirlo necesitabas saber los labels exactos de los elementos, su jerarquía, y si existían en el momento correcto. El ciclo era: escribir comando, correr, fallar, inspeccionar con `auto tree`, corregir, repetir.

La solución era obvia: un editor que mostrara el Simulador y el árbol de accesibilidad en tiempo real, junto al script que estas escribiendo.

## Stack

Consideramos tres opciones (documentado en [Capítulo 7, ADR 5](07-decisiones.md)):

- **Electron:** El estándar. ~200MB. JavaScript everywhere.
- **SwiftUI nativa:** El natural para un proyecto Swift. Pero no tiene un editor de código comparable a Monaco.
- **Tauri:** Rust backend + webview nativo. ~15MB. React + Monaco para el frontend.

Elegimos Tauri. El editor pesa ~15MB (13x menos que Electron), el backend en Rust puede llamar al CLI directamente, y Monaco nos da syntax highlighting, autocomplete, y temas oscuros gratis.

## Qué hace

```
┌──────────────────────────────────────────────────────────────┐
│  AutoPilot Editor                                             │
├────────────────────────────┬─────────────────────────────────┤
│                            │  Inspector                       │
│  Monaco Editor             │  ┌─────────────────────────────┐│
│                            │  │ Preview (screenshot real     ││
│  launch com.example.app    │  │ con overlays interactivos)   ││
│  waitFor "Login" 5         │  │                              ││
│  tap "Usuario"             │  │  [Login]  [Password]         ││
│  type "test@test.com"      │  │     [Entrar]                 ││
│  tap "Entrar"              │  │                              ││
│  waitFor "Home" 10         │  └─────────────────────────────┘│
│  screenshot ok.png         │  Tree                           │
│                            │  $0 AXWindow    "Simulator"     │
│                            │  $1 AXGroup     "App"           │
│                            │  $2 AXButton    "Login"         │
│                            │  $3 AXTextField "Usuario"       │
├────────────────────────────┴─────────────────────────────────┤
│  Terminal                                                     │
│  [1] launch com.example.app          Launched (245ms)        │
│  [2] waitFor "Login" 5               Found 'Login' (1203ms) │
│  [3] tap "Usuario"                   Tapped 'Usuario' (89ms)│
│  ▶ Play  ■ Stop  🗑 Clear  📂 Screenshots                    │
└──────────────────────────────────────────────────────────────┘
```

### Syntax highlighting

El editor reconoce el lenguaje `.auto`:
- **Keywords:** `launch`, `tap`, `type`, `waitFor`, `screenshot`, `inject`, etc.
- **Strings:** entre comillas dobles o simples
- **Comentarios:** líneas que empiezan con `#`
- **Números:** timeouts, índices
- Tema oscuro "AutoPilot" basado en Tokyo Night

### Autocomplete

35+ comandos con snippets. Pero lo interesante es que también autocompleta **elementos del Simulador en tiempo real**. El editor llama `auto tree` periodicamente y ofrece los labels de los elementos visibles como sugerencias.

### Inspector

Dos vistas:

**Preview:** Screenshot real del Simulador con overlays semi-transparentes sobre cada elemento. Click en un overlay inserta el comando `tap "Label"` en el editor.

**Tree:** Arbol jerárquico con índice `$N`, tipo (AXButton, AXTextField...), label, y coordenadas. Los índices `$N` se pueden usar en scripts: `tap $3` es equivalente a `tap "Usuario"`.

### Auto-wait

Entre cada paso de un script, el editor usa `AXObserver` para detectar cuando la UI del Simulador deja de cambiar. En vez de `sleep 2` hardcodeado, espera a que la UI se estabilice (0.3s de quietud, timeout de 3s). Esto elimina waits innecesarios sin introducir flakiness.

### Duplicados

Si una pantalla tiene dos elementos "Camera", `auto tap "Camera"` tapea el primero. `auto tap "Camera[2]"` tapea el segundo. El índice se resuelve en el orden del árbol AX — el mismo orden que UIAutomator usa en Android, lo que lo hace cross-platform.

## Arquitectura

```
editor/
├── setup.sh                # Instala dependencias + compila CLI
├── src/                    # Frontend React
│   ├── App.tsx             # Layout + toggle plataforma + Play/Stop
│   ├── App.css             # Tema AutoPilot (Tokyo Night)
│   └── Inspector.tsx       # Preview + Tree
├── src-tauri/              # Backend Rust
│   └── src/
│       └── lib.rs          # Comandos invoke()
│           ├── run_auto(args, platform)    # Ejecuta auto o auto-android
│           ├── get_ax_tree(platform)       # Arbol de accesibilidad
│           ├── get_element_index(platform) # Indices $N (iOS y Android)
│           ├── inspect(platform)           # Screenshot + tree + index
│           └── open_screenshots            # Abrir carpeta de capturas
```

El frontend usa `invoke()` de Tauri para llamar al backend Rust, pasando `platform` ("ios" o "android") en cada llamada. El backend elige el binario correcto (`auto` o `auto-android`), lo ejecuta como subproceso, y parsea su output. No hay servidor HTTP ni WebSocket — la comunicación es via IPC de Tauri.

## Soporte Android

Cuando agregamos el backend Android, el editor necesitaba hablar con dos binarios distintos: `auto` para iOS y `auto-android` para Android. La solución fue un toggle de plataforma en el toolbar.

### Toggle iOS / Android

Un par de botones en la barra superior permite cambiar entre plataformas. El estado `platform` se propaga a todas las llamadas `invoke()` — el backend Rust recibe `"ios"` o `"android"` y elige el binario correcto.

```
┌──────────────────────────────────────────────────────────────┐
│  AutoPilot  │ script.auto          [iOS] [Android]  Inspect  Play │
└──────────────────────────────────────────────────────────────┘
```

En Rust, `auto_binary(platform)` busca el binario en varias ubicaciones: junto al editor, en la raíz del proyecto, en `cli/.build/debug/`, o en el PATH. Esto resuelve un problema real: el editor corre desde `editor/src-tauri/` pero los binarios viven en la raíz del proyecto.

### Diferencias entre plataformas en el editor

| Aspecto | iOS | Android |
|---|---|---|
| Binario | `auto` | `auto-android` |
| Play/tap/tree | Funciona | Funciona |
| Inspector screenshot | Funciona | Funciona (via adb screencap) |
| Element index ($N) | Funciona | Funciona (via `index_from_tree` en Rust) |
| Auto-wait (AXObserver) | Funciona | No disponible |

### Element index en Android

En iOS, el element index (`$N`) se genera desde `auto index` en el CLI. En Android no existia un equivalente — `get_element_index` devolvia `[]`. La solucion fue `index_from_tree()` en el backend Rust del editor: genera los indices `$N` directamente desde el arbol de accesibilidad. Resuelve nodos genericos ("View" en Compose) usando el texto de sus hijos, y omite contenedores puros (FrameLayout, LinearLayout en profundidad 0-1) que no aportan informacion util. Tanto `get_element_index` como `inspect` ahora generan el indice para Android.

### Limitaciones actuales

Con el agente nativo, el tree Android se obtiene en ~30ms. El inspector ejecuta screenshot y tree **en paralelo** (threads Rust) para minimizar la latencia total. El screenshot sigue usando `adb screencap + pull` (~400ms) pero no bloquea el tree.

Un bug sutil nos costó tiempo: el callback `refreshTree` en React se creaba con `useCallback` pero sin `platform` en las dependencias. El closure capturaba el valor inicial (`"ios"`) y nunca se actualizaba al cambiar el toggle. Resultado: Inspect siempre ejecutaba `auto` (iOS) aunque el toggle mostraba Android. La solución fue agregar `platform` a las dependencias de `useCallback`.

### Setup

El editor necesita Rust, Node, y los binarios compilados. Para evitar que cada desarrollador tenga que resolver dependencias manualmente, creamos `editor/setup.sh`:

```bash
cd editor && ./setup.sh
```

El script detecta qué falta (Node, Rust, Swift, ADB), instala lo necesario (Rust via `rustup` automaticamente), instala dependencias npm, y compila ambos binarios CLI. Después de correrlo, `npm run tauri dev` funciona sin configuración adicional.

## Bugs que encontramos en producción

### El bug de comillas en el Inspector

El Inspector tenía un bug sutil: al hacer click en un elemento, insertaba el comando sin comillas cuando el label era multi-palabra.

```
# Label: "Usar código"
# Inspector generaba:
tap Usar código

# CLI parseaba:
tap "Usar"   ← argumento: "Usar", "código" se ignoraba
```

Un label de una palabra (`tap Login`) funcionaba porque el parser lo tomaba como un argumento. Pero `tap Usar código` llegaba al CLI como `tap` con argumento `Usar` — el resto de la línea se descartaba.

El bug era invisible durante el desarrollo porque los elementos de prueba tenían labels simples. Apareció cuando alguien intentó tapear "Usar código" en una app real.

**Fix:** El Inspector ahora envuelve el label en comillas dobles si contiene espacios:

```typescript
const command = label.includes(' ') ? `tap "${label}"` : `tap ${label}`
```

### Thread leak en timeout del Inspector

Al revisar el código para el fix de comillas, encontramos un segundo problema: el thread de Rust que ejecutaba `inspect` no se cancelaba en timeout.

El flujo original:

```rust
// lib.rs — ANTES
async fn inspect(platform: String) -> Result<InspectResult> {
    let result = tokio::spawn(async move {
        // screenshot + tree, puede tardar varios segundos
        run_inspect(platform)
    }).await?;
    result
}
```

Si el Simulador no respondía, `run_inspect` colgaba. El frontend tenía un timeout de 5 segundos en JavaScript, pero el thread de Rust seguía corriendo. La siguiente llamada a Inspect lanzaba otro thread. Y otra. En una sesión de trabajo de 2 horas con Inspects frecuentes, el editor acumulaba decenas de threads colgados y se volvía lento.

**Fix:** Cancelación explícita con `tokio::time::timeout`:

```rust
// lib.rs — DESPUÉS
async fn inspect(platform: String) -> Result<InspectResult> {
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        run_inspect(platform)
    )
    .await
    .map_err(|_| "Inspect timeout".to_string())?
}
```

Si el timeout dispara, el future se cancela y el thread se libera.

### Autocomplete incompleto en Android

El autocomplete del editor tiene listas de snippets por plataforma. `inspect` se agregó a la lista iOS pero no a la Android — un descuido simple que pasó desapercibido porque el test del editor siempre corría en iOS.

El patrón es predecible: el editor se construyó con iOS primero. Android fue retroalimentado sobre esa base. Cada vez que se agrega un comando nuevo hay que actualizarlo en tres lugares: CLI, autocomplete del editor, y documentación. Fácil de olvidar el del medio.

**Fix:** Una línea en `App.tsx` agregando `inspect` a la lista de snippets Android. El aprendizaje es que la lista debería ser compartida — mismo array para ambas plataformas, con excepciones explícitas — en vez de dos listas separadas que divergen con el tiempo.

---

## Qué aprendimos

1. **Monaco es absurdamente bueno.** Syntax highlighting, autocomplete con snippets, themes, multi-cursor — todo funciona out of the box. Implementar algo comparable en SwiftUI habría tomado meses.

2. **AXObserver es la clave del auto-wait.** Registrar un observer en el Simulador y esperar a que deje de emitir eventos es mucho más robusto que `sleep` o polling con `waitFor`.

3. **El inspector cambia la forma de escribir scripts.** Ver los elementos en tiempo real con sus labels y coordenadas elimina el ciclo de prueba-y-error que teníamos con el CLI puro.

4. **Tauri + React es un sweet spot.** El bundle es chico, el hot reload funciona, y el backend en Rust tiene performance nativo sin la complejidad de una app SwiftUI completa.

5. **El path del binario es más complejo de lo que parece.** En dev el editor corre desde `editor/src-tauri/`, en release desde el `.app` bundle. El binario puede estar en la raíz del proyecto, en `.build/debug/`, o en `/usr/local/bin/`. Tuvimos que buscar en 7 ubicaciones diferentes para cubrir todos los casos.

---

### Permisos de accesibilidad

El Inspector depende de la API `AXUIElement` de macOS, que requiere permisos de Accesibilidad. El binario `auto` no se puede agregar directamente a la lista de Accessibility (macOS requiere app bundles con Bundle ID). Los permisos se heredan del proceso padre: Terminal.app, Cursor, VS Code, o el `.app` instalado del editor. Si cambias de terminal o IDE, necesitas agregar el nuevo a System Settings > Accessibility. Documentado en detalle en [Capitulo 12](12-permisos-accesibilidad.md).

---

*Anterior: [Capítulo 4 — Inyección sin recompilar](04-inyeccion-sin-recompilar.md) | Siguiente: [Capítulo 6 — Alternativas](06-alternativas.md)*
