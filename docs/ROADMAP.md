# AutoPilot — Roadmap

**Última actualización:** 2026-04-19

Qué sigue, en orden de prioridad estratégica. Cada item tiene link a issue(s), estimación de esfuerzo y razón por la que está donde está.

---

## 🟥 Priority 1 — Próximo proyecto grande

### ARD-002 — In-process iOS Observer

**Epic:** [#111](https://github.com/fsaldivar-dev/AutoPilot/issues/111) · **Design:** [rfc/ARD-002](rfc/ARD-002-ios-in-process-observer.md) · **Estimación:** ~100-120h

Librería Swift/ObjC linkeada al binario iOS con `-force_load` durante build. Corre dentro del proceso, expone TCP socket + RPC. Arquitectura simétrica al agente Android.

**Habilita:**
- ✅ iPhone físico como target de primera clase (hoy bloqueado)
- ✅ SwiftUI completo sin fallback XCUI
- ✅ Latencia ~2-5ms por query (vs ~30-50ms AX actual)

**Fases deployables:**
- [#112](https://github.com/fsaldivar-dev/AutoPilot/issues/112) Phase 1 — libAutoPilotObserver.a + IPC en simulator (~35h)
- [#113](https://github.com/fsaldivar-dev/AutoPilot/issues/113) Phase 2 — SwiftUI introspection (~20h)
- [#114](https://github.com/fsaldivar-dev/AutoPilot/issues/114) Phase 3 — Device físico via devicectl (~30h)
- [#115](https://github.com/fsaldivar-dev/AutoPilot/issues/115) Phase 4 — `auto build --device` automation (~20h)
- [#116](https://github.com/fsaldivar-dev/AutoPilot/issues/116) Phase 5 — Fallback graceful (~15h)

**Por qué P1:** cierra el bloqueo más grande del producto (iOS físico) y elimina la dependencia de AX macOS que ha sido la raíz de múltiples post-mortems. El ROI por hora invertida es el más alto del roadmap.

---

## 🟨 Priority 2 — Calidad del recorder

### #91 — Gesture classification via XCUI

**Issue:** [#91](https://github.com/fsaldivar-dev/AutoPilot/issues/91) · **Estimación:** ~20-30h

Hoy el recorder emite `tap` para cualquier gesture. Drags terminan como `tap` + frustración. Scrolls detectados pero mal clasificados.

**Plan:**
- Distinguir tap (distancia <5px) vs longPress (duration >0.5s) vs drag (distancia >10px) vs scroll (multi-event)
- Usar XCUI para consultar si el elemento debajo es scrollable (`XCUIElementType.scrollView`, `table`, `collectionView`)
- Emitir `drag`, `longPress`, `scroll` con los deltas correctos

**Por qué P2:** mejora directa de la calidad de scripts grabados. Bloqueador para usuarios que graban flows complejos (drag-and-drop, swipe-to-delete).

### #62 — Benchmark suite vs Maestro/Appium

**Issue:** [#62](https://github.com/fsaldivar-dev/AutoPilot/issues/62) · **Estimación:** ~20h

Suite automatizada que mide:
- Cold start (launch + first tap)
- Warm taps (tap + tap + tap sobre elementos conocidos)
- Flow completo de login Explorea
- Variación estadística (n=10+)

Contra **Maestro**, **WDA** (Facebook), y potencialmente **Appium**. Outputs JSON + chart SVG auto-generado.

**Por qué P2:** provee evidencia de competitividad vs alternativas. Crítico para adoption si queremos hacer público el proyecto.

---

## 🟩 Priority 3 — Paridad Android con device físico

### #86 — AccountManager clearing para Google SSO

**Issue:** [#86](https://github.com/fsaldivar-dev/AutoPilot/issues/86) · **Estimación:** ~10h

Apps que usan "Sign in with Google" mantienen tokens en `AccountManager` del device, **no se borran con `clearState`**. Re-run del flow de login salta el paso de Google (porque "sigue logged in").

**Fix:** comando nuevo `auto-android clearAccounts com.google` que llama `AccountManager.removeAccount`. Requiere permisos adicionales en el agente APK.

### #53, #54 — Android recorder

- [#53](https://github.com/fsaldivar-dev/AutoPilot/issues/53) Detect system permission dialogs (~10h)
- [#54](https://github.com/fsaldivar-dev/AutoPilot/issues/54) Detect virtual keyboard input (~10h)

Mejoras de calidad del recorder Android equivalentes a lo que iOS ya tiene.

---

## 🟦 Priority 4 — Features nuevas

### #107 — `auto layout` ASCII cross-platform

**Issue:** [#107](https://github.com/fsaldivar-dev/AutoPilot/issues/107) · **Estimación:** ~15h

Renderiza el UI actual como ASCII art en terminal — útil para debug rápido, CI logs, snapshots regresión. Opt-in, reutiliza `.tree` del router.

### #55, #56 — Assertions visuales

- [#55](https://github.com/fsaldivar-dev/AutoPilot/issues/55) `assertOCR` via Vision.framework (~25h)
- [#56](https://github.com/fsaldivar-dev/AutoPilot/issues/56) `assertScreen` perceptual hash diff (~25h)

Validaciones visuales — complementarias al matching por label/identifier.

---

## 🔷 Ideas no-planeadas (parking lot)

Sin issue aún. Ideas que emergieron en conversaciones y vale anotar para retomar.

### Analytics-driven testing

Interceptar calls a Amplitude/Segment/Mixpanel desde la lib inyectada (ARD-002). Reemplazar `waitFor "Bienvenido"` por `waitForEvent "login_success"` → 10× más rápido, más robusto.

**Requiere ARD-002 antes.** Bloqueado hasta que el observer exista.

### Nuevo CLI `auto-macos` para apps macOS

AutoPilot ya tiene toda la infra AX macOS — solo faltaría un CLI dedicado y un `MacOSDeviceResolver`. Low effort, high impact si hay demanda.

### Integración con otros motores (parallel execution)

ARD-001 permite registrar múltiples backends con mismas capabilities. Con async + TaskGroup, podemos lanzar backends en paralelo y quedarnos con el primero que responde.

```swift
// Concepto (no implementado)
actor ActionRouter {
    func execute(_ action: Action) async throws -> ActionResult {
        // En lugar de escalation secuencial:
        try await withThrowingTaskGroup { group in
            for backend in capable(of: action.kind) {
                group.addTask { try await backend.execute(action) }
            }
            // Primer .success gana, cancela el resto
        }
    }
}
```

Permitiría usar Maestro, WDA, y AutoPilot en paralelo para máxima velocidad. Idea anotada del diseño ARD-001, sin priorizar.

### Telemetría del CLI

Opt-in. Qué comandos se usan, qué errores aparecen, latencias. Datos para priorizar features.

### Plugin system

Permitir que terceros agreguen backends sin modificar el core. Cargar `*.dylib` desde `~/.autopilot/plugins/` y registrarlos en el router.

### Cross-platform recorder unificado

Hoy hay recorders separados iOS (CGEventTap) y Android (getevent parser). Un recorder que capture ambos simultáneamente y genere un script `.auto` que corre en ambas plataformas sería un diferenciador único vs Maestro.

---

## Deuda técnica pendiente

Cosas que no duelen hoy pero eventualmente van a requerir trabajo:

### `LegacyBridgeAdapter` deprecation

Hoy los backends wrappean `SimulatorBridge` via `LegacyBridgeAdapter`. Cuando ARD-002 llegue, el nuevo `iOSAgentBackend` no necesita el adapter — es nativo del protocolo `Backend`. Eventualmente podemos **eliminar `LegacyBridgeAdapter`** y `DeviceBridge` legacy.

Bloqueado hasta que ARD-002 Phase 5 esté deployado (migración gradual).

### `HybridBridge` cleanup

`HybridBridge` existía antes del `ActionRouter` como escalation manual. Sigue vivo solo porque `AUTO_BRIDGE=hybrid` env var lo usa. Si nadie lo setea en producción, podemos borrarlo y simplificar.

### Tests de integración cross-platform

Hoy tenemos tests unitarios (121) pero los E2E solo se corren manualmente. Falta una suite que valide:
- Mismo script `.auto` corre en iOS sim + Android emulator + device físico (cuando ARD-002 exista)
- Output idéntico módulo labels platform-specific

### Documentación de la API de `Action`

`Action.swift` tiene ~40 casos. No hay docstring por case. Vale agregar comentarios claros de cada acción para devs de nuevos backends.

---

## Criterios de priorización

Cómo decido qué va primero:

1. **Desbloquea casos de uso nuevos** (ARD-002 → iOS device físico)
2. **Resuelve bugs que afectan al usuario final** (#91 gesture classification)
3. **Elimina deuda técnica antes de crecer** (split SimulatorBridge fue así)
4. **Baja barrera de adopción** (#62 benchmark para credibility)
5. **Nice-to-have features** (#107 layout ASCII)

Cuando dos items son similares en impacto, gana el **menor esfuerzo** (quick wins primero).

---

## Ver también

- [docs/HISTORY.md](HISTORY.md) — cómo llegamos acá
- [docs/POSTMORTEMS.md](POSTMORTEMS.md) — qué salió mal
- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — estado técnico actual
- [GitHub Issues](https://github.com/fsaldivar-dev/AutoPilot/issues) — lista live
