# Android — Backend (Futuro)

> Este backend aun no esta implementado. Este documento describe la arquitectura planeada.

## Arquitectura Propuesta

```mermaid
graph TB
    subgraph CLI["auto --platform android"]
        A[Mismos comandos que iOS]
    end

    subgraph Backend["Backend Android"]
        ADB["ADB<br/>Android Debug Bridge"]
        UIA["UIAutomator<br/>Inspeccion de UI"]
        INPUT["adb shell input<br/>Tap, type, swipe"]
        AM["adb shell am<br/>Activity Manager"]
        PM["adb shell pm<br/>Package Manager"]
    end

    subgraph Device["Dispositivo/Emulador"]
        APP["App Android"]
    end

    CLI --> ADB
    ADB --> UIA
    ADB --> INPUT
    ADB --> AM
    ADB --> PM
    UIA --> APP
    INPUT --> APP
    AM --> APP

    style CLI fill:#00D4FF,color:#000
    style Backend fill:#3DDC84,color:#000
    style Device fill:#333,color:#fff
```

## Mapeo de Comandos

| Comando AutoPilot | Equivalente Android |
|---|---|
| `auto list` | `adb devices` |
| `auto launch <pkg>` | `adb shell am start -n <pkg>/<activity>` |
| `auto terminate <pkg>` | `adb shell am force-stop <pkg>` |
| `auto install <apk>` | `adb install <apk>` |
| `auto tree` | `uiautomator dump` + parsear XML |
| `auto tap "Login"` | Buscar en XML + `adb shell input tap x y` |
| `auto type "texto"` | `adb shell input text "texto"` |
| `auto swipe up` | `adb shell input swipe x1 y1 x2 y2` |
| `auto screenshot` | `adb exec-out screencap -p > file.png` |

## Diferencias Clave con iOS

| Aspecto | iOS (AXUIElement) | Android (ADB) |
|---|---|---|
| Conexion | Proceso local (mismo Mac) | USB o TCP/IP |
| Inspeccion UI | Tiempo real (AX tree) | Snapshot (uiautomator dump) |
| Entrada | CGEvent (kernel) | adb shell input |
| Latencia | ~50-100ms | ~200-500ms |
| Permisos | TCC (Accesibilidad) | USB debugging habilitado |

## Prerequisitos

- Android SDK (`adb` en PATH)
- Dispositivo con USB debugging habilitado, o emulador corriendo
- No requiere root

## Contribuir

Si quieres ayudar a construir el backend de Android, revisa el [ROADMAP](../../ROADMAP.md) (Fase 5) y abre un issue para coordinar.
