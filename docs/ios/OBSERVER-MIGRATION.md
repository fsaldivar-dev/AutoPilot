# Guía de migración — Observer in-process (ARD-002)

Cómo integrar el observer `libAutoPilotObserver.a` en una app existente y qué
esperar cuando no está disponible. Complementa [ARD-002.md](ARD-002.md) (bitácora
técnica) — esto es la guía práctica.

## ¿Qué gano con el observer?

| Sin observer (default) | Con observer |
|---|---|
| AX macOS (rápido) + XCUI runner (deep) | Socket in-process (~ms, ve TODO el árbol) |
| `tap`/`tree` requieren Simulator.app con foco AX | No toca el foreground — el editor no pierde foco |
| Solo simulador | Base para device físico (Fase 3) |

## Integración en simulador (camino recomendado)

La vía sin tocar el proyecto: `auto build` inyecta el observer con `-force_load`:

```bash
auto config project MiApp.xcodeproj
auto config scheme MiApp
auto build            # compila con libAutoPilotObserver.a + ENABLE_DEBUG_DYLIB=NO
auto launch com.example.miapp
auto doctor           # → "Backend activo: ✓ Observer in-process (socket 7002)"
```

Manual (si controlas el build):

```bash
cd libs/AutoPilotObserver && make          # → build/libAutoPilotObserver.a
xcodebuild -project MiApp.xcodeproj -scheme MiApp -sdk iphonesimulator \
  OTHER_LDFLAGS='$(inherited) -force_load <repo>/libs/AutoPilotObserver/build/libAutoPilotObserver.a' \
  ENABLE_DEBUG_DYLIB=NO build
```

> `ENABLE_DEBUG_DYLIB=NO` es obligatorio en Xcode 26: sin él, `-force_load`
> no llega al binario final (el código va al debug dylib).

El observer arranca solo (`+load` de una clase ObjC dummy), abre el socket 7002
y habla el mismo protocolo JSON-line que el agente Android.

## Transición y fallback (sin restart)

Cada invocación de `auto` prueba el socket 7002 en el init
(`iOSDeviceResolver`): si responde, registra `iOSAgentBackend` con prioridad;
si no, cae a AX macOS + XCUI runner automáticamente. No hay estado persistente
— matar la app con observer y correr `auto tree` simplemente usa el fallback
en esa invocación.

- Diagnóstico: `auto doctor` → sección "Backend activo".
- Debug: `AUTO_FORCE_AX=1 auto tree` fuerza AXBackend aun con observer vivo
  (útil para comparar resultados).
- Motor manual: `AUTO_BRIDGE=simulator|xcui|hybrid` sigue funcionando para el
  path legacy.

## Device físico (spike — Fase 3 pendiente, #114)

Documentado en [ARD-002.md](ARD-002.md#device-físico-setup): build con
`make device` + `-force_load`, install/launch via `devicectl`, tunnel USB con
`iproxy 7002:7002`. Aún requiere `libimobiledevice` (la Fase 3 elimina la
dependencia).

## Limitaciones actuales

- Sin synth touches: `tap` usa `accessibilityActivate()` — gestos puros
  (pinch, long-press con gesture recognizer custom) requieren el fallback XCUI.
- El socket es 1:1 (un CLI a la vez), igual que el agente Android.
