# AutoPilot Editor

IDE para crear, editar y ejecutar scripts `.auto` con inspector visual del Simulador iOS.

## Stack

- **Tauri 2** — app nativa (~15MB vs ~200MB de Electron)
- **React + TypeScript** — frontend
- **Monaco Editor** — editor de codigo (el mismo de VS Code)
- **Rust** — backend que ejecuta comandos `auto`

## Features

### Editor con Syntax Highlighting

Editor Monaco con lenguaje `.auto` personalizado:
- **Keywords** en rojo: `tap`, `swipe`, `waitFor`, `launch`, etc.
- **Strings** en verde: `"Login"`, `"com.example.app"`
- **Comentarios** en gris: `# esto es un comentario`
- **Numeros** en naranja: coordenadas, timeouts
- **Tema** oscuro "AutoPilot" (Tokyo Night inspired)

### Autocomplete Inteligente

- **35+ comandos** con snippets y descripciones
- **Elementos del Simulador** — click Inspect para cargar el arbol AX
- **Duplicados resueltos** — `Camera[1]` (Image) vs `Camera[2]` (Button)
- Escribe `tap ` y el autocomplete muestra todos los elementos disponibles

### Inspector Visual

Dos modos:

**Preview** — Screenshot real del Simulador con overlays interactivos:
- Hover resalta el elemento con su tipo y label
- Click muestra acciones disponibles (tap, type, waitFor, etc.)
- Seleccionar accion inserta el comando al script
- Elementos ordenados por z-index (botones clickeables sobre grupos)

**Tree** — Arbol jerarquico de accesibilidad:
- Cada elemento con indice `$N`, icono por tipo, label y coordenadas
- Click muestra las mismas acciones que Preview
- Indentacion refleja la jerarquia del arbol AX

### Terminal

Panel inferior estilo terminal:
- Output de ejecucion en tiempo real (verde sobre negro)
- Boton **Play** / **Stop** para controlar ejecucion
- Boton **Clear** para limpiar output
- Boton **Screenshots** para abrir carpeta en Finder
- Indicador de ejecucion (dot pulsante)

### Ejecucion de Scripts

- **Play** ejecuta el script linea por linea
- **Stop** detiene la ejecucion en cualquier momento
- **Auto-wait** — espera automaticamente a que la UI se estabilice entre comandos (AXObserver)
- Cada paso muestra `[N] comando` + resultado en el terminal

### Indexacion de Elementos

Sistema `$N` para referenciar elementos sin ambiguedad:

```
$0  Button "Inicio"       [53,762]
$1  Button "Capturar"     [120,762]
$2  Image  "Camera"       [184,388]    ← hay dos "Camera"
$3  Button "Camera"       [178,580]    ← este es diferente
```

Para duplicados usa `Camera[2]` — funciona cross-platform (iOS y Android).

## Como correr

```bash
cd editor
npm install
npm run tauri dev
```

Primera compilacion de Rust toma ~2 min (descarga crates). Despues es instantaneo.

## Arquitectura

```
editor/
├── src/                    # Frontend React
│   ├── App.tsx             # App principal (toolbar, editor, terminal)
│   ├── App.css             # Estilos (tema oscuro)
│   └── Inspector.tsx       # Panel inspector (Preview + Tree)
├── src-tauri/              # Backend Rust
│   ├── src/lib.rs          # Comandos: run_auto, inspect, get_element_index
│   ├── Cargo.toml          # Dependencias Rust
│   └── tauri.conf.json     # Config Tauri
├── package.json            # Dependencias Node
└── vite.config.ts          # Config Vite
```

### Comandos Rust (backend)

| Comando | Descripcion |
|---|---|
| `run_auto(args)` | Ejecuta `auto <args>` y retorna stdout |
| `get_ax_tree()` | Parsea `auto tree` en elementos estructurados |
| `get_element_index()` | Parsea `auto index` con indices `$N` |
| `inspect()` | Screenshot + tree + index en un solo call |
| `open_screenshots()` | Abre carpeta screenshots en Finder |
