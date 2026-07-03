# Auditoría integral — 2026-07-03

Tres auditorías independientes ejecutadas por agentes especializados sobre main.
Resumen ejecutivo; los issues derivados están linkeados en cada sección.

## 1. QA de primer contacto (suites E2E reales)

**Calificación: 6/10** — "la mitad Android sola sería un 8". Flujo de 15 pasos:
Android 2/2 PASS (26s); iOS requirió 3 ediciones al mismo script (portabilidad ≈70%:
portable para acciones, no aún para aserciones).

### Lo que hace bien
1. Lenguaje `.auto` potente: if/else, try/catch, repeat, predicados — absorbe divergencias iOS/Android en un archivo
2. Velocidad Android excepcional (tap 100-250ms, tree 25ms)
3. Auto-recovery del agente real (kill total → siguiente comando repara en <1s)
4. `layout` como exploración es oro para usuarios nuevos
5. Recorder semántico honesto (desambiguación [N], comentarios de fragilidad, aviso de taps sintéticos)
6. Errores de parseo con línea exacta; assertOCR imprime lo reconocido (cazó un bug real de la demo)
7. Docs excepcionales; empaque del editor consistente

### Lo que no hace bien — las "tres mentiras en verde" (descalificantes para CI)
1. **[CRÍTICO]** tap Android resuelve clickable del overlay IME → tapea el teclado reportando éxito
2. **[CRÍTICO]** script con comandos inexistentes (`tapp`, `waitfor`) → imprime help 2x y sale exit 0 "Script completed"
3. **[ALTO]** `scrollTo` iOS reporta "Scrolled into view" sin scrollear (elemento bajo el tab bar)

Más: ciclo de vida del observer frágil (no sobrevive reboot; hint del doctor equivocado; sin
fallback hybrid a media corrida), assertOCR/screenshot iOS capturan la VENTANA DEL MAC
(`screencapture`) y no el device, replay de grabaciones mid-session roto por el preámbulo,
multi-tap con timing acumulado engañoso, lote de mensajes descuidados, `ping` iOS con
falso positivo (chequea Simulator.app, no el device).

## 2. Maestro vs AutoPilot (motores)

- **Ellos**: JVM + gRPC/Netty (Android 7001) + HTTP REST (iOS 22087, runner XCTest propio
  "zombie test", sin idb). Killer feature: tolerancia a flakiness de serie (asserts que
  pollean, `retryTapIfNoChange`, `waitForAnimationToEnd` con diff de imagen). Selectores
  relativos/regex, multi-window+toasts, Studio+Cloud, device iOS físico hoy.
- **Nosotros**: binario Swift 2MB, JSON-line debuggeable con nc, tree 34ms / tap 64ms
  (benchmark 2026-07-02; legacy 2008/2026ms), auto-recovery más robusto en la práctica
  (maestro-reset.sh existe por algo), camera mock único, script único iOS+Android.
- **Punto débil medible nuestro**: swipe 730ms vs 395ms del legacy (pacing de MOVE events).

Top 5 a adoptar (ROI): (1) auto-wait + retryTapIfNoChange sobre DeviceBridge — con tree a
34ms es casi gratis Y es el fix de fondo de las "mentiras en verde"; (2) multi-window/toasts
Android (getWindowRoots por reflection + listener de toasts); (3) health-check del runner
iOS estilo LocalXCTestInstaller; (4) fix del pacing de swipe (<200ms objetivo); (5) `auto
studio` mínimo sobre el editor existente.

## 3. Maestro Studio vs AutoPilot Editor

| Feature | Studio | Editor |
|---|---|---|
| Inspector visual / click-to-selector | ✓ / ✓ (sugiere alternativas) | ✓ / ✓ (inserta label crudo) |
| Autocomplete | comandos + selectores del device | 69 comandos + labels del tree |
| Playground / paso a paso | ✓ | ✓ (runBlock por bloque) |
| **Replay/debug de runs** | ✓ paso a paso, jump-to-point | ✗ (solo timing en terminal) |
| Mirror en vivo | ✓ continuo | parcial (~5fps solo durante run) |
| **Composición visual (If/Repeat/Try/Component)** | ✗ (YAML plano) | ✓ |
| Persistencia | archivos YAML | SQLite + env vars |
| AI asserts | experimental | ✗ |
| Distribución | web (requiere JVM) | .app nativa ~15MB |

Nos falta (priorizado): replay de runs (tenemos los datos, falta persistir en timeline),
mirror continuo, sugerencia de selectores alternativos, AI asserts.
Tenemos y ellos no: control flow visual, vista dual código↔bloques, componentes
reutilizables, persistencia estructurada, app nativa sin JVM.

## 4. Auditoría de asincronía (código bloqueante)

Top 5 por impacto real:
1. `AgentBridge.swift:75` — recv() SIN timeout: agente colgado a media respuesta congela
   CLI y editor para siempre (probeSocket sí tiene 1s; XCUIBridge es el modelo a copiar)
2. `DaemonServer.swift:224` — recv() del runner sin timeout: runner zombie deja a
   autopilotd en wedge permanente para todos los clientes futuros
3. `iOSSetup.swift:58,218,235` — 4.5s de sleeps fijos evitables por setup
4. `commands.rs:235-317` — comandos db_* síncronos en el MAIN THREAD de Tauri, amplificado
   por autosave que reescribe todo cada 500ms (persistence.ts:48)
5. `AgentBridge.swift:553` (2s fijos post-launch) + `CommandDispatcher.swift:220,235`
   (200ms por type)

No-problemas documentados: CLI one-shot bloqueante, polling de waitFor, runner mono-cliente
serial (por diseño), mirror con setInterval+guard, XCUIBridge (sockets bien hechos).

---

## Resolución (2026-07-03)

Los 13 issues derivados de esta auditoría (#151–#163) fueron resueltos, verificados y
mergeados a main el mismo día, junto con el retiro de AX del path por defecto (#164) y
un bug de runner encontrado en el camino (#149). Estado:

| Issue | Resultado |
|---|---|
| #151 tap IME | ✅ hit-test por centro + filtro por ventana (no tapea overlays IME) |
| #152 exit 0 falso | ✅ comando desconocido en script → FAIL+línea+sugerencia Levenshtein+exit 1 |
| #153 scrollTo iOS | ✅ valida viewport útil (descuenta tab/nav bar) → error tipado elementOccluded |
| #154 lifecycle observer | ✅ doctor honesto, degradación del router, detección de puerto secuestrado |
| #155 screenshot | ✅ era ruteo (XCUIBackend ganaba a MediaBackend); ahora framebuffer nativo simctl |
| #156 sockets sin timeout | ✅ SO_RCVTIMEO en AgentBridge (15s) y autopilotd (60s) → dispara recovery |
| #157 auto-wait | ✅ estabilización pre-acción + retryTap opt-in (~112ms overhead p50) |
| #158 timing multi-tap | ✅ cronómetro por-tap + estabiliza 1× (850ms plano vs 4050ms creciente) |
| #159 sleeps fijos | ✅ setup 5.6s→~3s (polls condicionados) |
| #160 editor async | ✅ db_* async, find_binary cacheado, autosave con diff |
| #161 replay recorder | ✅ preámbulo comentado en grabaciones mid-session |
| #162 cosméticos | ✅ 7 items (Agent error, tip DX, ping honesto, etc.) |
| #163 replay de runs | ✅ persistencia + panel de replay paso a paso (gap #1 vs Studio) |

Las "tres mentiras en verde" que descalificaban para CI están cerradas. La suite pasó de
328 a 436 tests. La killer feature de Maestro (auto-wait) ahora es nuestra.
