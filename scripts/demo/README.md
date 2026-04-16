# AutoPilot Demo — Explorea iOS + Android

Scripts que simulan el uso de AutoPilot en consola contra la app Explorea (iOS Settings como proxy + Android app real), con typewriter, colores, timing y capturas como evidencia.

## Archivos

- `demo-explorea.sh` — demo principal (iOS + Android)
- `start-daemon.sh` — helper para arrancar/parar `autopilotd` (necesario para escalación XCUI en iOS)
- `evidence/` — screenshots + logs generados por cada corrida

## Uso rápido

```bash
cd /ruta/a/frosty-sanderson

# 1. Compilar CLI + daemon
(cd cli && swift build)

# 2. Compilar el runner XCTest (solo la primera vez por máquina)
cd "Demo/iOS/Test Automatitacion"
UDID=$(xcrun simctl list devices booted -j | jq -r '.devices|..|.udid?//empty' | head -1)
xcodebuild build-for-testing \
  -project "Test Automatitacion.xcodeproj" \
  -scheme "Test Automatitacion" \
  -destination "platform=iOS Simulator,id=$UDID"
cd ../../..

# 3. Arrancar daemon (habilita la escalación XCUI)
./scripts/demo/start-daemon.sh start

# 4. Correr el demo
./scripts/demo/demo-explorea.sh           # iOS + Android
./scripts/demo/demo-explorea.sh ios       # solo iOS
./scripts/demo/demo-explorea.sh android   # solo Android
./scripts/demo/demo-explorea.sh --fast    # sin typewriter dramático
```

## Qué muestra el demo iOS

1. **Launch + screenshot** — Settings app como proxy de Explorea (mismo stack SwiftUI que Explorea pero sin auth).
2. **Comparación de árboles**:
   - `SimulatorBridge` ve `AXToolbar` (toolbar del sim, no de la app)
   - `XCUIBridge` ve `NavigationBar id=Configuración` con children queryables
   - Esta es la evidencia central del proyecto: **XCUI ve lo que AX macOS no ve**.
3. **Tap navegación** en fast-path (elemento visible en AX).
4. **Money shot** — tap "Configuración" (back button NavBar):
   - Con `AUTO_BRIDGE=simulator` — comportamiento viejo
   - Con HybridBridge — default nuevo, escala si hace falta
5. **Benchmark** de 3 iteraciones × 3 bridges con latencia.

## Qué muestra el demo Android

1. Verificar `auto-android ping` (AgentBridge socket activo)
2. Clear state + launch Explorea
3. Screenshot + tree (se ve el ComposeView con labels)
4. Fallback a FAB tap por coords si hay auth

## Dependencias

- macOS + Xcode 26.x instalado
- Simulator iOS booted (iPhone 17 o similar)
- Emulador Android corriendo (`adb devices` debe mostrarlo)
- App `shajaru.Test-Automatitacion` + `dev.autopilot.test.Explorea` instaladas

## Troubleshooting

**"autopilotd NO activo"**: corré `./scripts/demo/start-daemon.sh start` antes del demo.

**"sin simulador booted"**: abrí Simulator.app y lanza un iPhone.

**"xctestrun no encontrado"**: compilá el runner primero con `xcodebuild build-for-testing` (ver paso 2).

**Benchmark muestra "FAIL" en simulator**: pasa cuando Simulator.app no está en foreground. El script intenta traerlo con `osascript activate`, pero otras apps pueden robar el focus durante el bench.

**Demo iOS se queda en AuthView de Explorea real (no Settings)**: esta versión del demo usa Settings porque Face ID requiere timing cuidadoso en SwiftUI puro. Para correr contra Explorea real, editar `BUNDLE_IOS` y agregar el tap al botón Face ID.

## Salida esperada

```
╔═════════════════════════════════════════════╗
║ AutoPilot DEMO — Explorea (iOS + Android) ║
╚═════════════════════════════════════════════╝

✓ binarios OK  auto · auto-android · autopilotd
✓ iOS Sim iPhone 17 (Booted)
✓ Android emu emulator-5554
✓ autopilotd corriendo — runner ready ✓

▶ 1/6 — Terminate + launch Settings
$ auto terminate com.apple.Preferences
  │ Terminated com.apple.Preferences (534ms)
  ✓ ok (542ms)
...

▶ 3/6 — Comparación de árboles
  → SimulatorBridge (AX macOS externo):
     AXToolbar  [1216,62 456x52]
  → XCUIBridge (XCTest runner dentro del sim):
     NavigationBar  id=Configuración  [0,62 402x54]
     ...
```
