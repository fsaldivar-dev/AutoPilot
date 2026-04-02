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
├── src/                    # Frontend React
│   ├── App.tsx             # Layout principal
│   ├── Inspector.tsx       # Preview + Tree
│   ├── Terminal.tsx         # Output + controles
│   └── theme.ts            # Tema AutoPilot (Tokyo Night)
├── src-tauri/              # Backend Rust
│   └── src/
│       └── main.rs         # Comandos invoke()
│           ├── run_auto    # Ejecuta CLI, streaming de output
│           ├── get_ax_tree # Arbol de accesibilidad en JSON
│           └── inspect     # Atributos de un elemento
```

El frontend usa `invoke()` de Tauri para llamar al backend Rust. El backend ejecuta el binario `auto` como subproceso y parsea su output. No hay servidor HTTP ni WebSocket — la comúnicación es via IPC de Tauri.

## Qué aprendimos

1. **Monaco es absurdamente bueno.** Syntax highlighting, autocomplete con snippets, themes, multi-cursor — todo funcióna out of the box. Implementar algo comparable en SwiftUI habria tomado meses.

2. **AXObserver es la clave del auto-wait.** Registrar un observer en el Simulador y esperar a que deje de emitir eventos es mucho más robusto que `sleep` o polling con `waitFor`.

3. **El inspector cambia la forma de escribir scripts.** Ver los elementos en tiempo real con sus labels y coordenadas elimina el ciclo de prueba-y-error que teníamos con el CLI puro.

4. **Tauri + React es un sweet spot.** El bundle es chico, el hot reload funcióna, y el backend en Rust tiene performance nativo sin la complejidad de una app SwiftUI completa.

---

*Anterior: [Capítulo 4 — Inyección sin recompilar](04-inyeccion-sin-recompilar.md) | Siguiente: [Capítulo 6 — Alternativas](06-alternativas.md)*
