# AutoPilot — CLI de control de dispositivos iOS y Android

> "Information is power. But like all power, there are those who want to keep it for themselves.
> The world's entire scientific and cultural heritage [...] is increasingly being digitized and locked up
> by a handful of private corporations."
> — Aaron Swartz, Guerilla Open Access Manifesto (2008)

---

Este no es un manual de usuario. Es la documentación técnica de una investigación.

AutoPilot nació de una pregunta: ¿se puede controlar dispositivos iOS y Android desde la terminal sin servidores, test runners, ni dependencias pesadas? La respuesta involucró APIs de accesibilidad de macOS, un agente nativo Android con UiAutomation directa, inyección de dylibs, y 10 intentos de mockear una cámara que no existe.

Documentamos todo el proceso — los errores, los callejones sin salida, las decisiones — para que cualquier ingeniero que enfrente problemas similares tenga un punto de partida. El conocimiento es libre.

---

## Contenido

### El libro

1. **[El problema](01-el-problema.md)** — Por qué controlar dispositivos desde la terminal no debería ser tan difícil
2. **[Arquitectura](02-arquitectura.md)** — AXUIElement (iOS) + UiAutomation (Android) + DeviceBridge: el protocolo que unifica ambos
3. **[La cámara virtual](03-la-camara-virtual.md)** — 10 intentos, 9 fracasos, y lo que aprendimos de cada uno
4. **[Inyección sin recompilar](04-inyeccion-sin-recompilar.md)** — DYLD_INSERT_LIBRARIES como herramienta de inyección de código (un enfoque que nadie más usa)
5. **[El editor](05-el-editor.md)** — De CLI a IDE visual con Tauri + Monaco
6. **[Alternativas](06-alternativas.md)** — Maestro, Appium, AXe, XCUITest, idb: que hacen bien y por qué elegimos otro camino
7. **[Decisiones](07-decisiones.md)** — ADRs 1-8: Swift puro, AX públicas, no YAML, dos binarios + DeviceBridge
8. **[Por qué es libre](08-por-que-es-libre.md)** — La deuda con el open source, el problema de la IA privatizada, y por qué documentamos los fracasos
9. **[El agente Android](09-el-agente-android.md)** — De 2100ms a 75ms: un APK de instrumentación que habla directo con UiAutomation
10. **[Paridad Android](10-paridad-android.md)** — Label[N], clipboard (y la restricción silenciosa de Android 10), y tres intentos de camera mock
11. **[El benchmark](11-el-benchmark.md)** — AutoPilot vs Maestro vs WDA: metodología, resultados, y por qué Maestro es 2.5x más lento por diseño

### Apendices

- **[Referencia de comandos](apendices/comandos.md)** — Los ~30 comandos del CLI, agrupados por categoria
- **[Guia de scripts .auto](apendices/scripts.md)** — Sintaxis, patrones, buenas practicas y errores comunes
- **[Variables de entorno](apendices/variables-entorno.md)** — Inyeccion de datos para CI/CD
- **[CI/CD](apendices/ci-cd.md)** — GitHub Actions, permisos TCC, configuracion de runners
- **[Troubleshooting](apendices/troubleshooting.md)** — Errores comunes y como resolverlos

### Referencia

- **[Roadmap](../../ROADMAP.md)** — Fases futuras (Android, web, recorder)
- **[Bitacora](../camera/BITACORA.md)** — Diario de laboratorio crudo (cada sesion, cada intento)
- **[Android backend](../android/README.md)** — AgentBridge, agente nativo, comandos implementados

---

## Cómo leer este libro

Si quieres entender **por qué existe** AutoPilot, lee el [Capítulo 1](01-el-problema.md).

Si quieres entender **cómo funciona** por dentro, lee el [Capítulo 2](02-arquitectura.md).

Si quieres ver **ingeniería inversa real** — intentos fallidos, ARM64 PAC, ObjC runtime hacks, descubrimientos que no estan documentados en ningún otro lugar — lee los Capítulos [3](03-la-camara-virtual.md) y [4](04-inyeccion-sin-recompilar.md).

Si quieres ver **datos duros** de velocidad vs las alternativas, lee el [Capítulo 11](11-el-benchmark.md).

Si quieres **usar** AutoPilot, ve al [README principal](../../README.md).

---

*Todo el contenido esta en español. El código fuente y los ejemplos usan convenciones en ingles donde es idiomático (nombres de funciones, variables, APIs).*
