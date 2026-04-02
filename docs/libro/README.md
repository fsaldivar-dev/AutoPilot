# AutoPilot — Ingenieria de automatizacion iOS desde macOS

> "Information is power. But like all power, there are those who want to keep it for themselves.
> The world's entire scientific and cultural heritage [...] is increasingly being digitized and locked up
> by a handful of private corporations."
> — Aaron Swartz, Guerilla Open Access Manifesto (2008)

---

Este no es un manual de usuario. Es la documentacion tecnica de una investigacion.

AutoPilot nacio de una pregunta simple: ¿se puede controlar el Simulador iOS sin XCUITest, sin servidor, sin dependencias? La respuesta involucro APIs de accesibilidad de macOS, inyeccion de dylibs via DYLD_INSERT_LIBRARIES, swizzle de 25 metodos de AVFoundation, y 10 intentos de mockear una camara que no existe.

Documentamos todo el proceso — los errores, los callejones sin salida, las decisiones — para que cualquier ingeniero que enfrente problemas similares tenga un punto de partida. El conocimiento es libre.

---

## Contenido

### El libro

1. **[El problema](01-el-problema.md)** — Por que la automatizacion iOS esta rota y que observacion lo cambio todo
2. **[Arquitectura](02-arquitectura.md)** — AXUIElement, CGEvent, simctl, AppleScript: las 4 capas que reemplazan a XCUITest
3. **[La camara virtual](03-la-camara-virtual.md)** — 10 intentos, 9 fracasos, y lo que aprendimos de cada uno
4. **[Inyeccion sin recompilar](04-inyeccion-sin-recompilar.md)** — DYLD_INSERT_LIBRARIES como herramienta de testing (un enfoque que nadie mas usa)
5. **[El editor](05-el-editor.md)** — De CLI a IDE visual con Tauri + Monaco
6. **[Alternativas](06-alternativas.md)** — Maestro, Appium, AXe, XCUITest, idb: que hacen bien y por que elegimos otro camino
7. **[Decisiones](07-decisiones.md)** — ADRs: por que Swift puro, por que AX publicas, por que no YAML

### Apendices

- **[Referencia de comandos](apendices/comandos.md)** — Los ~30 comandos del CLI
- **[Variables de entorno](apendices/variables-entorno.md)** — Inyeccion de datos para CI/CD
- **[CI/CD](apendices/ci-cd.md)** — GitHub Actions, permisos TCC, configuracion de runners
- **[Troubleshooting](apendices/troubleshooting.md)** — Errores comunes y como resolverlos

### Referencia

- **[Roadmap](../../ROADMAP.md)** — Fases futuras (Android, web, recorder)
- **[Bitacora](../../camera/BITACORA.md)** — Diario de laboratorio crudo (cada sesion, cada intento)

---

## Como leer este libro

Si quieres entender **por que existe** AutoPilot, lee el [Capitulo 1](01-el-problema.md).

Si quieres entender **como funciona** por dentro, lee el [Capitulo 2](02-arquitectura.md).

Si quieres ver **ingenieria inversa real** — intentos fallidos, ARM64 PAC, ObjC runtime hacks, descubrimientos que no estan documentados en ningun otro lugar — lee los Capitulos [3](03-la-camara-virtual.md) y [4](04-inyeccion-sin-recompilar.md).

Si quieres **usar** AutoPilot, ve al [README principal](../../README.md).

---

*Todo el contenido esta en espanol. El codigo fuente y los ejemplos usan convenciones en ingles donde es idiomatico (nombres de funciones, variables, APIs).*
