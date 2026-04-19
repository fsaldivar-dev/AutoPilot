# AutoPilot — Documentación

Automatización E2E para iOS y Android en Swift puro, sin dependencias externas. Dos CLIs (`auto`, `auto-android`) + editor Tauri + recorder semántico + agente Android nativo.

## Empezar acá

Lee estos cuatro en orden si sos nuevo:

1. **[HISTORY.md](HISTORY.md)** — cómo llegamos al estado actual. Timeline con logros y fracasos.
2. **[ARCHITECTURE.md](ARCHITECTURE.md)** — cómo está hecho el sistema hoy. Diagramas + estructura de archivos + invariantes.
3. **[POSTMORTEMS.md](POSTMORTEMS.md)** — qué no funcionó y qué aprendimos. 6 casos de estudio con root cause.
4. **[ROADMAP.md](ROADMAP.md)** — qué sigue. Priorizado con estimaciones.

## Documentos de decisión (RFCs/ARDs)

- **[rfc/ARD-001-backend-pattern.md](rfc/ARD-001-backend-pattern.md)** — Command + Capability Discovery. Mergeado en PR #106.
- **[rfc/ARD-002-ios-in-process-observer.md](rfc/ARD-002-ios-in-process-observer.md)** — Lib inyectada para iOS device físico. **Propuesto, sin implementar.**
- **[rfc/recorder-semantico.md](rfc/recorder-semantico.md)** — recorder que emite scripts semánticos en lugar de coordenadas. Parcialmente implementado.

## Libro técnico

Explicación conceptual en 15 capítulos — [libro/](libro/). Útil si querés entender **por qué** elegimos ciertos approach (camera mock sin recompilar, agente Android nativo, swizzle ObjC, etc.).

Capítulos notables:
- [libro/02-arquitectura.md](libro/02-arquitectura.md) — diseño base pre-ARD-001
- [libro/09-el-agente-android.md](libro/09-el-agente-android.md) — por qué un APK nativo
- [libro/13-el-recorder-semantico.md](libro/13-el-recorder-semantico.md) — modelo del recorder
- [libro/15-el-segundo-motor.md](libro/15-el-segundo-motor.md) — XCUI runner

Apéndices: [comandos](libro/apendices/comandos.md), [variables de entorno](libro/apendices/variables-entorno.md), [troubleshooting](libro/apendices/troubleshooting.md), [scripts](libro/apendices/scripts.md).

## Por área

### iOS
- [ios/ARQUITECTURA.md](ios/ARQUITECTURA.md) — wrappers AX, SimulatorBridge antes del split
- [ios/XCUI-BRIDGE.md](ios/XCUI-BRIDGE.md) — arquitectura del runner XCTest
- [ios/VARIABLES_ENTORNO.md](ios/VARIABLES_ENTORNO.md) — `AUTO_BRIDGE`, `AUTOPILOT_RUNNER_TEST_ID`, etc.

### Android
- [android/README.md](android/README.md) — overview
- [android/SDK-SETUP.md](android/SDK-SETUP.md) — setup de ANDROID_HOME + emulator

### Editor
- [editor/README.md](editor/README.md) — Tauri + React + Monaco

### Camera mock (iOS)
- [camera/README.md](camera/README.md) — cómo funciona la inyección
- [camera/DESARROLLO.md](camera/DESARROLLO.md) — internals
- [camera/BITACORA.md](camera/BITACORA.md) — diario de hallazgos

### Recorder
- [recorder/HALLAZGOS.md](recorder/HALLAZGOS.md) — experimentos del recorder
- [recorder/BITACORA.md](recorder/BITACORA.md) — diario de desarrollo
- [xcui/BITACORA.md](xcui/BITACORA.md) — diario del bridge XCUI

### Benchmark
- [benchmark/MAESTRO-RECOVERY.md](benchmark/MAESTRO-RECOVERY.md) — recovery script cuando Maestro rompe el simulator

### Validación real
- [validacion/BITACORA.md](validacion/BITACORA.md) — hallazgos validando contra apps de producción

## Recursos externos

- [Repo GitHub](https://github.com/fsaldivar-dev/AutoPilot)
- [Issues](https://github.com/fsaldivar-dev/AutoPilot/issues)
- [Pull Requests](https://github.com/fsaldivar-dev/AutoPilot/pulls)

## Convenciones del proyecto

- **Swift puro, sin dependencias externas**, sin Python, sin runtimes
- **Documentación en español**, código y commits en inglés
- **Sin emojis en código** (ver CLAUDE.md)
- **Un diario (BITACORA.md) por área** — hallazgos crudos que después se consolidan en docs técnicos

Para contribuir, ver [CLAUDE.md](../CLAUDE.md) en la raíz del repo — guía de convenciones + workflow.
