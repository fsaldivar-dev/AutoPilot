# ARD-001 — Backend Pattern + ActionRouter

**Estado:** Aprobado  
**Fecha:** 2026-04-18  
**Autor:** fsaldivar-dev  
**Issues:** #96 #97 #98 #99 #100 #101 #102 #103 #104 #105

---

## Contexto

AutoPilot tiene un protocolo `DeviceBridge` con 53 métodos que obliga a cada implementación a declarar capacidades que no posee:

- `XCUIBridge` lanza `notImplemented()` en 36 de 53 métodos
- `HybridBridge` solo escala 5 de 53 métodos (tap, longPress, doubleTap, clear, scroll)
- `CLI/main.swift` reimplementa ~40 comandos que ya existen en `CommandDispatcher`
- `SimulatorBridge` acumula 1964 LOC mezclando 6 responsabilidades distintas

El resultado es una arquitectura que crece en capas de cebolla: cada vez que aparece un nuevo motor (simulator → xcui → hybrid → agent), se crea un wrapper nuevo encima del anterior. Agregar un nuevo backend requiere tocar múltiples archivos. Agregar un nuevo comando requiere editar 3 lugares.

**Problema raíz:** El protocolo `DeviceBridge` es un contrato total — impone implementar TODO o lanzar `notImplemented()`. Esto fuerza los híbridos y la duplicación.

---

## Decisión

Reemplazar `DeviceBridge` con **Backend protocol + CapabilityRegistry + ActionRouter**.

### Paradigma: Command Pattern + Capability Discovery

```
Script .auto
    ↓
ActionParser → [Action]        ← comandos como valores, no strings
    ↓
ActionRouter                   ← único punto de entrada
    ├── consulta CapabilityRegistry
    ├── escala automáticamente si elementNotFound
    └── backends en orden de prioridad

Backends (pequeños, focalizados)
  iOS:     AXBackend · XCUIBackend · SimCtlBackend · MediaBackend
  Android: AgentBackend · AdbBackend
```

### Protocolo Backend

```swift
public enum ActionKind: Hashable {
    case tap, type, tree, search, screenshot
    case install, launch, terminate
    case biometricEnroll, biometricMatch
    // ... todos los casos
}

public protocol Backend: AnyObject, Sendable {
    var capabilities: Set<ActionKind> { get }
    func execute(_ action: Action) async throws -> ActionResult
}
```

Cada backend declara **solo lo que sabe hacer**. El router nunca le pide algo que no declaró.

### ActionRouter con escalation

```swift
public actor ActionRouter {
    func execute(_ action: Action) async throws -> ActionResult {
        let candidates = await registry.capable(of: action.kind)
        var lastError: Error?
        for backend in candidates {
            do {
                return try await backend.execute(action)
            } catch let e as BridgeError where e == .elementNotFound {
                lastError = e
                continue  // escalar al siguiente backend
            }
        }
        throw lastError ?? ActionRouterError.noBackendForAction(action.kind)
    }
}
```

El escalation ya no está hardcodeado en `HybridBridge` — es una propiedad del router. Cualquier par de backends se beneficia automáticamente.

---

## Consecuencias

### Positivas

- **Un backend = una responsabilidad.** `AXBackend` solo hace AX. `SimCtlBackend` solo llama xcrun. Unidades testables de forma independiente.
- **Nuevo motor = nuevo archivo.** Agregar WDA, Maestro, o WebDriver es registrar un nuevo backend. Sin tocar nada existente.
- **CLI delgado.** `CLI/main.swift` pasa de 873 a ~120 LOC. Solo construye el router y delega.
- **Escalation completa.** Cualquier combinación de backends escala automáticamente, no solo los 5 casos de HybridBridge.
- **iOS y Android comparten router.** El mismo `ActionRouter` con diferente registry. El script no sabe la diferencia.

### Negativas / Riesgos

- **Período de transición.** `DeviceBridge` y `Backend` coexisten durante las Fases 0-3. Mitigado con `LegacyBridgeAdapter`.
- **Escalation semántica.** El comportamiento de HybridBridge (try AX → retry XCUI en elementNotFound) debe reproducirse explícitamente en el orden de registro de backends. Si el orden cambia, el comportamiento cambia silenciosamente.
- **Async migration.** Los bridges actuales son síncronos. `Backend.execute` es `async`. Requiere `Task {}` wrappers en el adapter durante la transición.

---

## Invariantes de Compatibilidad

Estos invariantes deben mantenerse en **todas las fases** de la migración:

1. `auto run script.auto` produce el mismo output observable
2. El schema `.autopilot` no cambia
3. `AUTO_BRIDGE=simulator|xcui|hybrid` funciona hasta Fase 4
4. El daemon `autopilotd` no se modifica
5. El protocolo NDJSON del modo `interactive` no cambia
6. Scripts `.auto` existentes funcionan sin modificación

---

## Mapa de Migración

| Bridge actual | LOC | → Backend nuevo | LOC estimado |
|--------------|-----|-----------------|-------------|
| `SimulatorBridge` (AX + input) | 1964 | `AXBackend` | ~400 |
| `SimulatorBridge` (simctl + device mgmt) | — | `SimCtlBackend` | ~400 |
| `SimulatorBridge` (recording + screenshot) | — | `MediaBackend` | ~200 |
| `XCUIBridge` | 332 | `XCUIBackend` | ~300 |
| `HybridBridge` | 255 | eliminado (→ ActionRouter) | 0 |
| `AgentBridge` | 744 | `AgentBackend` | ~500 |
| `AdbLegacyBridge` | 828 | `AdbBackend` | ~600 |
| `CLI/main.swift` | 873 | slim launcher | ~120 |
| `CLIAndroid/main.swift` | 632 | slim launcher | ~100 |

**Total actual:** ~6,628 LOC en bridges + CLIs  
**Total propuesto:** ~2,620 LOC — reducción del 60%

---

## Fases

```
Fase 0 (2d)  — Backend.swift · CapabilityRegistry · ActionRouter · LegacyBridgeAdapter
Fase 1 (2d)  — Slim iOS CLI (873 → ~120 LOC)
Fase 2 (1d)  — Slim Android CLI (632 → ~100 LOC)
Fase 3a (5d) — AXBackend · SimCtlBackend · MediaBackend · XCUIBackend
Fase 3b (3d) — AgentBackend · AdbBackend  [paralelo a 3a]
Fase 4 (2d)  — DeviceResolver · eliminar HybridBridge · eliminar LegacyBridgeAdapter
```

Total estimado: ~15 días. Cada fase deja el CLI funcional y deployable.

---

## Verificación por Fase

Cada fase debe pasar antes de mergear:

```bash
swift build                                          # sin warnings nuevos
swift test                                           # sin regresiones
auto run scripts/examples/camera-test.auto           # output idéntico
auto-android run scripts/examples/android-login.auto # output idéntico
# CI verde en GitHub Actions
```

---

## Issues Relacionados

| Issue | Fase | Acción |
|-------|------|--------|
| [#96](https://github.com/fsaldivar-dev/AutoPilot/issues/96) | 0 | Backend + ActionRouter (P0) |
| [#97](https://github.com/fsaldivar-dev/AutoPilot/issues/97) | 0 | ARD-001 docs |
| [#98](https://github.com/fsaldivar-dev/AutoPilot/issues/98) | 1 | Slim iOS CLI |
| [#99](https://github.com/fsaldivar-dev/AutoPilot/issues/99) | 3a | AXBackend |
| [#100](https://github.com/fsaldivar-dev/AutoPilot/issues/100) | 2 | Slim Android CLI |
| [#101](https://github.com/fsaldivar-dev/AutoPilot/issues/101) | 3a | SimCtlBackend + MediaBackend |
| [#102](https://github.com/fsaldivar-dev/AutoPilot/issues/102) | 3a | XCUIBackend |
| [#103](https://github.com/fsaldivar-dev/AutoPilot/issues/103) | 3b | AgentBackend + AdbBackend |
| [#104](https://github.com/fsaldivar-dev/AutoPilot/issues/104) | 4 | DeviceResolver + limpieza |
| [#105](https://github.com/fsaldivar-dev/AutoPilot/issues/105) | 3a | Test suite |
| [#52](https://github.com/fsaldivar-dev/AutoPilot/issues/52) | 3a | Resuelto por AXBackend |
| [#59](https://github.com/fsaldivar-dev/AutoPilot/issues/59) | 3b | Resuelto por AgentBackend |
| [#50](https://github.com/fsaldivar-dev/AutoPilot/issues/50) | 3a | Habilitado por AXBackend |
| [#79](https://github.com/fsaldivar-dev/AutoPilot/issues/79) | 3a | Desbloqueado por AXBackend |
