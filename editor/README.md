# AutoPilot Composer (editor)

Aplicacion nativa (Tauri 2 + React + TypeScript) que consume el CLI
`auto` / `auto-android` a traves del protocolo NDJSON de `auto interactive`.

No es un editor de scripts — es un **Composer** de bloques visuales,
inspirado en Figma y Scratch. Cada comando se verifica contra el
dispositivo real antes de materializarse como bloque. Los componentes
emergen del uso: seleccionas bloques y los "agrupas", infiriendo los
parametros automaticamente.

## Arquitectura

```
┌─ UI (React + Zustand) ─────────────────────────────────┐
│  AppShell → CommandBar → BlockCanvas → Inspector       │
├─ Services (TypeScript) ────────────────────────────────┤
│  executor.ts │ db.ts                                   │
├─ Tauri commands (Rust async + tokio) ──────────────────┤
│  executor_* │ db_* │ inspect │ bundle_cli_path         │
├─ NDJSON session manager (Rust) ────────────────────────┤
│  spawn(auto interactive) → read_line loop → frames     │
├─ CLIs bundleados (no editados) ────────────────────────┤
│  auto (iOS) │ auto-android                             │
└─────────────────────────────────────────────────────────┘
```

- **editor/src-tauri/src/**
  - `cli.rs` — resolucion + ejecucion async del CLI
  - `tree.rs` — parsers de AX tree e indice (tests)
  - `executor.rs` — sesiones NDJSON async con FIFO + timeout
  - `db.rs` — SQLite (rusqlite bundled) para projects/flows/components/env/runs
  - `commands.rs` — handlers #[tauri::command] async
  - `lib.rs` — bootstrap (tokio + Arc<ExecutorRegistry> + Db)

- **editor/src/**
  - `app/AppShell.tsx` — layout 3 columnas + toolbar + status bar
  - `composer/CommandBar.tsx` — input Raycast-style con autocomplete siempre abierto
  - `composer/autocomplete/` — tokenizer + 5 providers + ranking
  - `composer/catalog/commands.json` — 60+ comandos tipados
  - `blocks/` — CommandBlock, LogicBlock (C-shape), ComponentBlock
  - `library/GroupAsComponentModal.tsx` — inferencia de parametros de `$variables`
  - `projects/`, `inspector/`, `timeline/`, `toolbar/`, `share/`
  - `state/store.ts` — Zustand con 4 slices (project/composer/executor/ui)
  - `domain/` — types, zod schemas, row serializers
  - `services/` — wrappers de Tauri commands

## Desarrollo

```bash
npm install
./refresh-binaries.sh         # debug build (copia auto/auto-android)
npm run tauri dev             # editor con hot-reload
```

Tests:

```bash
npm run test                  # vitest unit + RTL (36 tests)
cd src-tauri && cargo test    # backend (13 tests)
npm run test:e2e              # Playwright human-sim (5 escenarios)
```

Build release:

```bash
./refresh-binaries.sh --universal   # requiere swift build -c release --arch arm64 --arch x86_64
npm run tauri build                 # produce .dmg con CLIs embebidos
```

## Modo human-sim

`testing/human-sim/*.spec.ts` son escenarios Playwright que actuan como un
humano usando el editor. Genera screenshots en `testing/evidence/` como
evidencia visual. Requiere que `window.__store__` este expuesto (solo en
modo dev).

Escenarios incluidos:

1. `01-first-launch` — empty state + crear proyecto
2. `02-command-autocomplete` — tipear `ta`, Tab completa a `tap`
3. `03-group-as-component` — seleccionar 3 bloques, inferencia de 2 params
4. `04-env-vars` — chips normales y secretos con masking
5. `05-share-export` — export JSON no filtra secretos

## Bundling

Los CLIs se distribuyen embebidos en `AutoPilot Editor.app/Contents/MacOS/`:

- `auto-aarch64-apple-darwin` — iOS CLI
- `auto-android-aarch64-apple-darwin` — Android CLI

`refresh-binaries.sh --universal` usa `lipo -create` para generar binarios
universal macOS (arm64 + x86_64). `find_binary()` en `cli.rs` resuelve con
cascada: bundle → dev paths → PATH fallback (backward compat).

## Autocomplete

El catalogo vive en `src/composer/catalog/commands.json` (60+ comandos con
params tipados). Como el CLI no tiene `--help --json`, el catalogo se
mantiene a mano — el CLI es estable.

Providers:

- CommandProvider — del catalogo, filtra por plataforma
- ElementProvider — live del device (via `tree_refresh`)
- ComponentProvider — componentes del proyecto con firmas tipadas
- EnvVarProvider — activa tras `$`, enmascara secretos
- RecentProvider — ultimos 5 bloques ejecutados

Contexto (tokenizer):

- Dentro de `[role]` → filtra roles
- Tras `within ` → solo containers (group, toolbar, list, etc)
- Tras accion keyword (`tap `, `type `) → elementos
- Tras `$` → variables

Performance objetivo: <50ms por keystroke para 100+ suggestions.
