# Apéndice C — Variables de entorno

AutoPilot usa variables de entorno en tres contextos distintos: build de la app de prueba, inyección de datos al Simulador en runtime, y configuración del ambiente CI/CD.

---

## Variables de build (Xcode)

Se configuran en el Build Settings de Xcode o en el `.autopilot` del proyecto.

| Variable | Propósito | Valor por defecto | Cuándo usar |
|---|---|---|---|
| `ENABLE_DEBUG_DYLIB` | Habilita carga de dylibs externas en el Simulador | `NO` | Requerido para `auto build` / camera mock |
| `OTHER_LDFLAGS` | Flags de linker para force-load del dylib de mock | (vacío) | Se agrega automáticamente con `auto build` |

### `ENABLE_DEBUG_DYLIB`

Sin este flag en `NO` (paradójicamente, `NO` es el valor que *habilita* el comportamiento), Xcode 26+ bloquea la carga de dylibs externas en el Simulador. La variable se setea en el archivo `.autopilot` al correr `auto config`:

```
# .autopilot
project = App.xcodeproj
scheme = App
bundle = com.example.app
image = foto.jpg
```

`auto build` lee ese archivo y compila la app con los flags correctos.

---

## Variables de inyección al Simulador

El Simulador de iOS propaga variables de entorno con prefijo `SIMCTL_CHILD_` a las apps que lanza. AutoPilot usa esto para pasar configuración a dylibs inyectadas.

| Variable | Propósito | Ejemplo |
|---|---|---|
| `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` | Path de la dylib a inyectar | `/tmp/autopilot-camera.dylib` |
| `SIMCTL_CHILD_AUTOPILOT_IMAGE` | Path de la imagen mock de cámara (hot-swap) | `/tmp/autopilot-camera-image.jpg` |

### Cómo funciona el prefijo `SIMCTL_CHILD_`

Cuando se lanza una app via `xcrun simctl launch`, las variables de entorno del proceso que llama a `simctl` con prefijo `SIMCTL_CHILD_` se propagan a la app — sin el prefijo. Así, `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` llega a la app como `DYLD_INSERT_LIBRARIES`.

```bash
# AutoPilot hace esto internamente:
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/tmp/autopilot-camera.dylib \
SIMCTL_CHILD_AUTOPILOT_IMAGE=/tmp/foto.jpg \
xcrun simctl launch booted com.example.app
```

La app ve:
```
DYLD_INSERT_LIBRARIES = /tmp/autopilot-camera.dylib
AUTOPILOT_IMAGE = /tmp/foto.jpg
```

### Hot-swap de imagen

`AUTOPILOT_IMAGE` no es necesaria en el `launch` — la dylib de camera mock la lee en cada frame del preview. Para cambiar la imagen sin relaunch:

```bash
# El CLI sobreescribe el archivo; la dylib lo detecta en el siguiente frame
cp nueva-foto.jpg /tmp/autopilot-camera-image.jpg
```

O via el comando:
```
camera feed nueva-foto.jpg
```

---

## Variables de configuración del CLI

| Variable | Propósito | Valor por defecto |
|---|---|---|
| `AUTO_DEVICE_UDID` | UDID del simulador/dispositivo a usar | Primer dispositivo booteado |
| `AUTO_HOST` | Host del agente Android | `127.0.0.1` |
| `AUTO_PORT` | Puerto del agente Android | `9008` |
| `AUTO_LEGACY` | Forzar AdbLegacyBridge en Android | (no seteada = AgentBridge) |

### `AUTO_DEVICE_UDID`

Útil en CI donde hay múltiples simuladores corriendo:

```bash
UDID=$(xcrun simctl list --json devices | jq -r '.devices[][] | select(.isAvailable) | .udid' | head -1)
AUTO_DEVICE_UDID=$UDID ./auto run script.auto
```

---

## Variables de CI/CD

### iOS (GitHub Actions, runner `macos-15`)

| Variable | Propósito | Setear en |
|---|---|---|
| `DEVELOPER_DIR` | Path de Xcode a usar | `xcode-select` o env var |
| `TCC_PERMISSIONS` | Permisos de privacidad (Camera, Microphone) | `xcrun simctl privacy grant` |

En GitHub Actions, los runners `macos-15` tienen Xcode preinstalado pero no tienen permisos TCC por defecto. El workflow de CI los otorga explícitamente:

```yaml
- name: Grant TCC permissions
  run: |
    xcrun simctl privacy booted grant camera dev.autopilot.test.App
    xcrun simctl privacy booted grant microphone dev.autopilot.test.App
```

### Android (GitHub Actions, runner `ubuntu-latest` o `macos-15`)

| Variable | Propósito | Valor típico en CI |
|---|---|---|
| `ANDROID_HOME` | SDK de Android | `/usr/local/lib/android/sdk` |
| `ANDROID_AVD_HOME` | Directorio de AVDs | `~/.android/avd` |
| `JAVA_HOME` | JDK para compilar el agente | Preinstalado en runner |
| `TOTAL_RUNS` | Número de runs en benchmark suite | `3` (default: `11`) |

```yaml
# .github/workflows/android.yml (fragmento)
env:
  ANDROID_HOME: /usr/local/lib/android/sdk
  
steps:
  - name: Start emulator
    run: |
      $ANDROID_HOME/emulator/emulator -avd pixel9 -no-window &
      adb wait-for-device
      
  - name: Forward agent port
    run: adb forward tcp:9008 localabstract:autopilot
    
  - name: Run tests
    run: ./auto-android run scripts/examples/android-login.auto
```

---

## Variables del benchmark

| Variable | Propósito | Valor por defecto |
|---|---|---|
| `TOTAL_RUNS` | Número de runs por herramienta | `11` |
| `RESULTS_DIR` | Directorio de resultados JSONL | `scripts/benchmark-suite/benchmark-results/` |
| `EVIDENCE_DIR` | Directorio de screenshots | `scripts/benchmark-suite/evidence/` |

```bash
# Correr benchmark con 3 runs (más rápido para desarrollo)
TOTAL_RUNS=3 ./scripts/benchmark-suite/run.sh
```

---

*Volver a: [Referencia de comandos](comandos.md) | [Guía de scripts .auto](scripts.md)*

*[Índice del libro](../README.md)*
