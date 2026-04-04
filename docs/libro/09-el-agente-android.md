# Capítulo 9 — El agente Android

## El problema: 2 segundos por tap

Cuando implementamos el backend Android de AutoPilot (ver [Capítulo 2](02-arquitectura.md)), hicimos lo más directo: forkear `adb shell uiautomator dump` para obtener el árbol de UI, parsear el XML, buscar el elemento, y forkear `adb shell input tap x y` para tapear.

Funcionaba. Pero cada tap tomaba **2.1 segundos**. Un script de 18 pasos tardaba 24 segundos. Para comparar, el mismo flujo en iOS toma ~5 segundos.

La latencia venía de tres fuentes:

1. **`uiautomator dump` (~2000ms):** Lanza un proceso nuevo en el dispositivo, escanea toda la jerarquía de vistas, serializa a XML, escribe a un archivo, y lo transmite por USB. Es una herramienta de debugging, no de automatización.

2. **Fork de `adb` por cada comando (~50-100ms):** Cada operación (`tap`, `type`, `swipe`) spawneaba un proceso `adb` nuevo en el host. Handshake ADB, autenticación, ejecución, respuesta.

3. **XML parsing (~5ms):** Irónicamente, la parte que más preocupaba era la más rápida.

La pregunta era: ¿cómo bajan de 2 segundos a algo comparable con iOS (~90ms)?

---

## Investigación: cómo lo hacen los demás

Antes de escribir código, investigamos cómo Maestro, Appium, scrcpy y otras herramientas resuelven el mismo problema.

### Maestro

Maestro despliega un **APK de instrumentación** en el dispositivo que corre como un proceso long-lived. Adentro hay un servidor HTTP que recibe comandos y los ejecuta via UIAutomator2. La comunicación host-dispositivo pasa por `adb forward` (port forwarding sobre USB). Adicionalmente, Maestro usa `dadb` — una implementación pura en Kotlin del protocolo ADB que evita forkear el binario `adb`.

Resultado: ~50-150ms por tap.

### Appium

Mismo approach: un APK servidor (`appium-uiautomator2-server`) que corre como instrumentación. Habla W3C WebDriver protocol sobre HTTP. Más overhead de protocolo que Maestro, pero misma arquitectura fundamental.

### scrcpy

scrcpy no hace automatización de UI (solo mirror + input), pero su approach de input es el más rápido de todos: un JAR lanzado via `app_process` que inyecta eventos directamente via `InputManager` con un **protocolo binario sobre socket**. Un tap toma <5ms.

### El patrón común

Todas las herramientas rápidas comparten la misma arquitectura:

```
┌─────────────────┐         ┌──────────────────────────┐
│  Host            │         │  Dispositivo              │
│                  │         │                           │
│  CLI/Driver ────────────────► Agente persistente       │
│  (una conexión   │  socket │  (UiAutomation directa,   │
│   persistente)   │         │   sin fork por comando)   │
└─────────────────┘         └──────────────────────────┘
```

Nadie rápido usa `uiautomator dump`. Todos mantienen un proceso vivo en el dispositivo que tiene acceso directo a `UiAutomation` — la API del framework Android que `uiautomator` usa internamente, pero sin el overhead de serialización a XML y escritura a disco.

---

## Decisión: Instrumentation + LocalSocket

Teníamos dos caminos para el agente:

| | AccessibilityService | Instrumentation |
|---|---|---|
| Setup | `adb shell settings put secure...` | `adb install` + `am instrument` |
| Input: tap | `dispatchGesture()` ~10-50ms | `injectInputEvent()` ~1-3ms |
| Key events | Solo Back/Home | Cualquier tecla |
| Sobrevive crash | Sí | No (pero self-instrument lo evita) |

Elegimos **Instrumentation** porque `injectInputEvent()` es 10x más rápido que `dispatchGesture()` y soporta key events (Enter, Delete, Tab — esenciales para formularios).

Para el socket, elegimos **`LocalServerSocket`** (abstract Unix domain socket) en lugar de TCP. No necesita permiso `INTERNET`, no tiene overhead TCP, y se conecta via `adb forward localabstract:autopilot`.

---

## Implementación: 4 archivos, 200KB

El agente es un proyecto Android mínimo. Sin activities, sin UI, sin dependencias externas.

```
agent/app/src/main/kotlin/dev/autopilot/agent/
├── AgentInstrumentation.kt   ← Entry point (am instrument)
├── SocketServer.kt           ← LocalServerSocket + command dispatch
├── TreeSerializer.kt         ← AccessibilityNodeInfo → JSON
└── InputInjector.kt          ← UiAutomation.injectInputEvent()
```

### AgentInstrumentation

Extiende `android.app.Instrumentation`. En `onStart()` obtiene `UiAutomation` (la API system-wide que puede ver y controlar todas las apps) y lanza el `SocketServer`. El proceso nunca llama `finish()` — se queda vivo indefinidamente.

### SocketServer

Abre `LocalServerSocket("autopilot")` y acepta conexiones. El protocolo es simple: una línea JSON por request, una línea JSON por response.

```json
→ {"method": "ping"}
← {"result": "pong", "api": 36}

→ {"method": "tap", "params": {"target": "Login"}}
← {"result": {"success": true, "x": 540, "y": 1200}}

→ {"method": "tree"}
← {"result": [{...árbol completo...}]}
```

### TreeSerializer

Recorre el `AccessibilityNodeInfo` recursivamente y serializa cada nodo a JSON con el **mismo formato** que usa el iOS bridge — mismas keys (`role`, `title`, `label`, `identifier`, `frame`, `children`). Esto permite que `TreePrinter` y `CommandDispatcher` funcionen idénticos en ambas plataformas.

```
AccessibilityNodeInfo              JSON output
─────────────────────              ───────────
className: "android.widget.       "role": "TextView"
            TextView"
text: "Explorea"                   "title": "Explorea"
contentDescription: ""             "label": ""
viewIdResourceName: "com.app:      "identifier": "com.app:id/title"
                     id/title"
boundsInScreen: Rect(423,1359,     "frame": {"x":423, "y":1359,
                     857,1485)              "width":434, "height":126}
```

### InputInjector

Usa `UiAutomation.injectInputEvent()` para inyectar `MotionEvent` y `KeyEvent` directamente en el pipeline de input del sistema. Un tap son dos eventos: `ACTION_DOWN` + `ACTION_UP`. Un swipe son ~20 eventos `ACTION_MOVE` entre down y up.

---

## Resultados

Comparamos los árboles del método viejo (`uiautomator dump` + `UIAutomatorParser`) y el nuevo (agente + `TreeSerializer`) en la misma pantalla. **Son idénticos** — mismos nodos, mismos roles, mismos textos, mismas coordenadas.

La diferencia es el tiempo:

| Operación | uiautomator dump | Agente socket | Mejora |
|---|---|---|---|
| **Ping** | 67ms | **0ms** | ∞ |
| **Tree (cold)** | 2000ms | **315ms** | 6x |
| **Tree (warm)** | 2000ms | **3-6ms** | **330-660x** |
| **Tap por label** | 2100ms | **75-171ms** | **12-28x** |

El tree "warm" es 3-6ms porque `UiAutomation` ya tiene la conexión abierta con `AccessibilityManagerService`. No hay proceso que lanzar, no hay XML que generar, no hay archivo que escribir. Solo recorre los nodos en memoria y serializa.

---

## Tropiezo: findAccessibilityNodeInfosByText() y Compose

La implementación inicial del `tap` usaba `AccessibilityNodeInfo.findAccessibilityNodeInfosByText()` — la API optimizada del framework que busca sin recorrer el árbol completo.

No funcionó. En una app de Jetpack Compose, la llamada retornaba lista vacía para textos que claramente estaban en pantalla ("Explorea", "Desbloquear con PIN").

```kotlin
// Esto retorna vacío en Compose:
root.findAccessibilityNodeInfosByText("Explorea")  // → []

// Pero el nodo existe:
// TreeSerializer muestra: {"role":"TextView", "title":"Explorea", ...}
```

La causa: Compose genera su propio árbol de accesibilidad via `SemanticsNode`, no via el `View` system tradicional. La API `findAccessibilityNodeInfosByText()` delega al framework que busca en el `View` hierarchy — pero los nodos de Compose no están ahí de la misma forma.

La solución fue implementar búsqueda recursiva manual — recorrer el árbol nodo por nodo con `getChild(i)` y comparar `getText()` y `getContentDescription()`. Más lento que la API nativa (porque cada `getChild()` es un IPC call), pero funciona con Views y Compose por igual.

```kotlin
private fun findRecursive(node: AccessibilityNodeInfo, query: String, exact: Boolean): AccessibilityNodeInfo? {
    val text = node.text?.toString()?.lowercase() ?: ""
    val desc = node.contentDescription?.toString()?.lowercase() ?: ""

    val matches = if (exact) text == query || desc == query
                  else text.contains(query) || desc.contains(query)

    if (matches) return AccessibilityNodeInfo.obtain(node)

    for (i in 0 until node.childCount) {
        val child = node.getChild(i) ?: continue
        val found = findRecursive(child, query, exact)
        child.recycle()
        if (found != null) return found
    }
    return null
}
```

Hacemos dos pasadas: primero match exacto (performance), después contains (flexibilidad). El tap completo con búsqueda recursiva toma 75-171ms — aceptable.

---

## Cómo usar el agente

```bash
# Compilar (una vez)
cd agent && ./gradlew assembleDebug

# Instalar (una vez por dispositivo)
adb install app/build/outputs/apk/debug/app-debug.apk

# Lanzar agente
adb shell am instrument -w dev.autopilot.agent/.AgentInstrumentation &

# Conectar socket
adb forward tcp:9008 localabstract:autopilot

# Usar
echo '{"method":"ping"}' | nc localhost 9008
echo '{"method":"tree"}' | nc localhost 9008
echo '{"method":"tap","params":{"target":"Login"}}' | nc localhost 9008
```

---

## Qué aprendimos

1. **`uiautomator dump` es para debugging, no para automatización.** La herramienta que Google provee es 330x más lenta que acceder a la misma API (`UiAutomation`) directamente. La documentación no dice esto en ningún lado.

2. **Instrumentation es la puerta a `UiAutomation`.** El framework Android requiere contexto de instrumentación para acceder a la API de accesibilidad system-wide. No hay shortcut — necesitas un APK y `am instrument`.

3. **`LocalServerSocket` + `adb forward localabstract:` es el patrón correcto.** No TCP (overhead innecesario), no HTTP (overhead innecesario). Socket directo, JSON plano, una línea por mensaje.

4. **`findAccessibilityNodeInfosByText()` no funciona con Compose.** Nadie documenta esto. La API del framework que debería buscar texto en la UI no ve los nodos que Jetpack Compose genera. La solución es búsqueda recursiva manual.

5. **El primer intento funcionó.** A diferencia de la cámara virtual (10 intentos), el agente Android funcionó en la primera iteración. La diferencia: esta vez investigamos antes de codificar. Entendimos la arquitectura de Maestro, Appium y scrcpy antes de escribir una línea.

6. **El formato del tree importa.** Usar las mismas keys que el bridge iOS (`role`, `title`, `label`, `identifier`, `frame`, `children`) permite que toda la infraestructura compartida (`TreePrinter`, `CommandDispatcher`) funcione sin cambios.

---

## Integración con el CLI

Con el agente funcionando, el siguiente paso fue conectarlo al CLI `auto-android`. Creamos `AgentBridge` — un nuevo `DeviceBridge` que habla con el agente via TCP socket en lugar de forkear `adb` por cada comando.

El viejo `AdbBridge` se renombró a `AdbLegacyBridge` y se archivó (no eliminó) para poder medir la diferencia. El CLI ahora acepta `--legacy` para usar el bridge viejo:

```bash
# Default: agente nativo (rápido)
auto-android tap "Login"              # ~150ms

# Legacy: fork adb por cada comando (lento, para benchmarks)
auto-android --legacy tap "Login"     # ~2100ms
```

### Benchmarks finales end-to-end

| Operación | Legacy (`--legacy`) | AgentBridge (default) | Mejora |
|---|---|---|---|
| **Tree** | 2397ms | **29ms** | **82x** |
| **Tap por label** | ~2100ms | **123-286ms** | **8-17x** |
| **waitFor** | ~2000ms | **300ms** | **7x** |
| **exists** | ~2000ms | **306ms** | **7x** |

La arquitectura final del CLI Android:

```
auto-android tap "Login"
    │
    ├─ AgentBridge (default)
    │   └─ TCP socket → localhost:9008 → agente → UiAutomation
    │       find: 10-50ms, inject: 1-3ms, total: ~150ms
    │
    └─ AdbLegacyBridge (--legacy)
        └─ fork adb → uiautomator dump → parse XML → fork adb input tap
            dump: 2000ms, parse: 5ms, input: 100ms, total: ~2100ms
```

### Qué delega AgentBridge a adb

No todo pasa por el agente. Los comandos de control de dispositivo (`launch`, `terminate`, `install`, `screenshot`, `list`) siguen usando `adb` directamente porque no requieren acceso a `UiAutomation` — son operaciones de shell. Solo los comandos de UI (tree, tap, type, swipe) pasan por el socket.

## Siguiente paso

El agente cubre las operaciones de UI. Falta agregar `screenshot` y `launch` al protocolo del agente para eliminar completamente la dependencia de `adb shell` para operaciones frecuentes. También falta el auto-setup: que `AgentBridge` detecte si el agente está corriendo y lo levante automáticamente si no.

---

*Anterior: [Capítulo 8 — Por qué es libre](08-por-que-es-libre.md) | Siguiente: [Capítulo 10 — Paridad Android](10-paridad-android.md)*

*[Índice del libro](README.md)*

*[Índice del libro](README.md)*
