# Capítulo 11 — El benchmark

## La pregunta que no podíamos responder

Durante meses dijimos "AutoPilot es más rápido" basándonos en intuición. Un tap tardaba ~90ms en iOS. WDA tomaba ~300ms según la documentación de Appium. Maestro se sentía lento.

Pero teníamos un problema de credibilidad. Los mismos autores de una herramienta midiendo su herramienta es el tipo de benchmark que nadie debería creer. ¿Habíamos optimizado inconscientemente el script de AutoPilot? ¿Habíamos elegido un flujo que favorecía nuestra arquitectura?

La única forma de responder la pregunta era construir una suite que midiera las tres herramientas en las mismas condiciones, con el mismo flujo, en el mismo dispositivo, con evidencia visual de que cada herramienta ejecutó el mismo test.

---

## Qué medimos y por qué

### El flujo

Elegimos un flujo de login — no porque sea el más representativo de uso real, sino porque es el mínimo que permite comparar de forma significativa:

1. Launch de la app
2. Esperar splash screen
3. Tap en "Usar código"
4. Ingresar PIN (4 dígitos)
5. Confirmar
6. Esperar home screen
7. Tap en categoría
8. Scroll

Ocho pasos, cinco taps. Suficiente para que las diferencias arquitectónicas sean visibles, pero no tan largo que las diferencias de red o estado del simulador distorsionen los resultados.

El mismo flujo lógico en tres formatos:

```
# AutoPilot (.auto)          # Maestro (YAML)              # WDA (JavaScript/Appium)
launch dev.autopilot...      appId: dev.autopilot...       driver.execute('mobile: launchApp'...)
waitFor "Explorea" 10        - launchApp                   await driver.$('~Explorea').waitForExist...
tap "Usar código"            - tapOn: "Usar código"        await driver.$('~Usar código').click()
tap "1"                      - tapOn: "1"                  await driver.$('~1').click()
...                          ...                           ...
```

### Lo que no medimos

Deliberadamente no medimos:
- **Startup time** de la herramienta (no es relevante para CI — el runner ya está levantado)
- **Memoria** (relevante para runs largos, no para esta comparativa)
- **Flakiness** (cuántas veces falla en 100 runs) — esto es más importante que velocidad, pero requiere una suite diferente

---

## Levantar las herramientas

Maestro fue sencillo: `brew install mobile-dev-inc/tap/maestro`. Un binario, sin dependencias adicionales para iOS Simulator.

WDA fue un proceso de cuatro pasos:

```bash
npm install -g appium @appium/xcuitest-driver
appium driver install xcuitest
appium --port 8100              # servidor en background
# En una sesión separada...
iproxy 8100 8100                # port forward al simulador
```

El primer `appium test` tardó dos minutos — compila el XCTest runner y lo despliega en el simulador. Cada run posterior tarda ~3 segundos en reconectar.

### El primer obstáculo: la versión de iOS

El script de setup usaba `xcrun simctl list` para encontrar el simulador booteado y parsear la versión:

```bash
# Patrón original
ios_version=$(xcrun simctl list | grep -oE 'iOS [0-9]+\.[0-9]+' | head -1)
```

En Xcode 16+, la versión de iOS 26 aparece como `iOS 26-0` (con guion) en la salida de `simctl list`. El regex `[0-9]+\.[0-9]+` no matcheaba, `ios_version` quedaba vacía, y los comandos `simctl` subsiguientes fallaban con mensajes confusos sobre "simulador no encontrado".

```bash
# Fix
ios_version=$(xcrun simctl list | grep -oE 'iOS [0-9]+[-. ][0-9]+' | head -1)
```

Took us three debug sessions to find. La señal era que el log decía "Simulator booted" pero el siguiente comando fallaba. El simulador estaba bien — el regex estaba mal.

### El segundo obstáculo: WDA y el simulador reiniciado

Cada vez que el benchmarking reiniciaba el simulador (entre runs), WDA perdía la conexión. `iproxy` seguía corriendo pero el endpoint `/status` de WDA retornaba timeout. El script ahora verifica:

```bash
if ! curl -sf http://localhost:8100/status > /dev/null 2>&1; then
    echo "ERROR: WDA no está corriendo."
    echo "Levanta Appium: appium --port 8100"
    echo "Y el port forward: iproxy 8100 8100"
    exit 1
fi
```

Mejor fallar rápido con un mensaje claro que fallar en el medio del benchmark con un timeout de 30 segundos.

---

## Metodología de medición

```bash
run_benchmark() {
    local tool=$1
    local test=$2
    shift 2
    
    local start=$(date +%s%N)
    "$@"
    local end=$(date +%s%N)
    
    local duration_ms=$(( (end - start) / 1000000 ))
    echo "{\"tool\":\"$tool\",\"test\":\"$test\",\"duration_ms\":$duration_ms}" >> results.jsonl
}
```

`date +%s%N` da nanosegundos desde epoch en macOS con GNU coreutils (instalado via brew). El tiempo incluye todo: startup del proceso, conexión con el simulador, ejecución del flujo, y shutdown. Esto es lo que importa para CI — no el tiempo "puro" de tap, sino el tiempo real que el desarrollador espera.

Tres runs por herramienta. Promedio simple (no eliminamos outliers — si una herramienta tiene outliers frecuentes, eso es información).

---

## Resultados

**iPhone 16 Pro, iOS 26.3, 3 runs, tiempo promedio:**

| Test | AutoPilot | Maestro | WDA |
|---|---|---|---|
| Login flow | **10.2s** ★ | 26.1s | 11.7s |
| Biometric | **7.6s** ★ | N/A | 10.7s |

Maestro no puede hacer biometric — sus scripts corren en un sandbox JavaScript sin acceso a `simctl`, AppleScript, o comandos del sistema. Face ID requiere controlar los menús del Simulator desde macOS. (Ver [Capítulo 2](02-arquitectura.md) para detalles de la capa AppleScript.)

### Varianza entre runs

| Herramienta | Run 1 | Run 2 | Run 3 | Desv. Est. |
|---|---|---|---|---|
| AutoPilot | 10.1s | 10.3s | 10.2s | 0.1s |
| WDA | 11.4s | 11.8s | 12.0s | 0.3s |
| Maestro | 25.8s | 26.2s | 26.3s | 0.3s |

AutoPilot es consistente. WDA tiene varianza baja pero medible — el round-trip HTTP agrega jitter. Maestro tiene la mayor varianza absoluta pero en términos relativos es comparable a WDA.

---

## Por qué Maestro es 2.5x más lento

La hipótesis inicial fue el stack. Maestro corre en JVM — arrancar la JVM, el gRPC client, la conexión con XCTest driver. Todo eso tiene overhead.

Pero mirar los logs en verbose (`maestro test --verbose`) cuenta una historia diferente:

```
[00:00.000] launchApp
[00:02.410] assertVisible: "Explorea"    ← wait-for-idle: 2.1s
[00:02.415] ✓ found
[00:02.416] tapOn: "Usar código"
[00:04.502] assertVisible: ...           ← wait-for-idle después del tap: 2.1s
[00:05.209] tapOn: "1"
[00:07.310] tapOn: "2"                   ← otro wait-for-idle: 2.1s
...
```

Cada tap incluye un `wait-for-idle` de ~2 segundos. Con cinco taps, eso es ~10 segundos de waits que AutoPilot no tiene.

Esta es una decisión de diseño deliberada de Maestro. Su documentación lo llama "smart synchronization" — en vez de requerir que los scripts tengan `waitFor` explícitos, Maestro espera automáticamente a que la UI esté estable después de cada acción. En ambientes lentos (apps con animaciones largas, servidores lentos), esto elimina flakiness.

AutoPilot usa `AXObserver` para detectar quietud de UI. Si la UI se estabiliza en 200ms, el siguiente paso empieza en 200ms. Si tarda 2 segundos, espera 2 segundos. No hay floor artificial.

**¿Quién tiene razón?** Depende del caso de uso. Para una app bancaria con animaciones complejas en producción, el floor de 2s de Maestro puede ser más robusto. Para una app de demo en simulador con animaciones de 100ms, es 10 segundos desperdiciados por run.

```
Desglose aproximado de tiempo por herramienta (login, 8 pasos):

AutoPilot:
  launch + wait splash      ~2.5s
  5 taps × ~90ms            ~0.5s
  waits (AXObserver)        ~7.0s   ← domina, pero son waits reales de UI
  ─────────────────────────────────
  Total                     ~10.2s

Maestro:
  launch + wait splash      ~2.5s
  5 taps × ~50ms            ~0.3s
  wait-for-idle × 8 pasos   ~16.8s  ← floor artificial 2s × 8
  ─────────────────────────────────
  Total                     ~26.1s

WDA (Appium):
  launch + wait splash      ~3.0s
  5 taps × ~150ms           ~0.8s
  HTTP round-trips overhead ~0.5s
  waits (polling)           ~7.2s
  ─────────────────────────────────
  Total                     ~11.7s
```

---

## El dashboard

`scripts/benchmark-suite/report/comparison-dashboard.html` — un archivo HTML estático que no requiere servidor ni build step. Usa React + htm (JSX en el browser via `htm/react`).

Seis tabs:
1. **Overview** — resultados con gráficas de barras, metodología, notas
2. **APIs** — 37 capacidades comparadas (biometric, clipboard, camera, index, CI support, etc.)
3. **Arquitectura** — diagrama de capas de cada herramienta
4. **Timeline** — animación con los screenshots reales capturados durante el benchmark
5. **Scripts** — los tres scripts (.auto, YAML, JS) con syntax highlighting lado a lado
6. **Roadmap** — qué falta medir

### El problema del syntax highlighting en HTML estático

Monaco no está disponible fuera de un módulo ES. Para el dashboard estático, implementamos highlighting manual con regex. El problema: la regex de keywords (`tap`, `waitFor`, etc.) colisionaba con strings — un keyword dentro de un string se resaltaba como keyword.

```javascript
// Problema: "waitFor" dentro de un string se resaltaba
text = text.replace(/\bwaitFor\b/g, '<span class="keyword">waitFor</span>')
// → tap "<span class="keyword">waitFor</span> elemento"  ← incorrecto
```

Solución: placeholder trick.

```javascript
const strings = []
// 1. Extraer strings y reemplazar con placeholders
text = text.replace(/"[^"]*"/g, match => {
    strings.push(match)
    return `§${strings.length - 1}§`
})
// 2. Aplicar keywords (ya no hay strings que colisionen)
text = text.replace(/\btap\b/g, '<span class="keyword">tap</span>')
// 3. Restaurar strings
strings.forEach((s, i) => {
    text = text.replace(`§${i}§`, `<span class="string">${s}</span>`)
})
```

---

## Qué faltó medir

**Flakiness:** La métrica más importante para adopción. Un tool que tarda 30s pero nunca falla puede ser mejor que uno que tarda 10s pero falla 1 de cada 5 runs. No medimos esto — requiere 100+ runs y análisis estadístico.

**Startup del runner:** Para el primer run del día, WDA tarda ~2 minutos compilando el XCTest runner. Esto es irrelevante para CI (el runner se mantiene caliente), pero muy relevante para desarrollo local.

**Apps reales vs demo:** La app demo tiene animaciones mínimas. En una app real con transiciones, los números de AutoPilot subirían (AXObserver esperaría más). Los de Maestro subirían menos (ya tienen el floor de 2s).

**Android:** La suite existe solo para iOS. El agente Android tiene latencias diferentes — un benchmark Android vs iOS sería interesante para entender cuánto de la diferencia es plataforma vs herramienta.

---

## Qué aprendimos

1. **Los benchmarks propios requieren rigor metodológico.** El primer instinto fue medir "tiempo de tap" aislado. Pero eso no es lo que el desarrollador experimenta. El tiempo de extremo a extremo, incluyendo waits de UI, es la métrica correcta.

2. **El stack JVM de Maestro no es el cuello de botella.** Habríamos apostado por "JVM startup = lentitud". Pero Maestro arranca rápido — es el `wait-for-idle` de 2s por step lo que domina. La arquitectura del sistema importa más que el lenguaje.

3. **Los waits de UI dominan el tiempo total.** En AutoPilot, ~70% del tiempo de login es `waitFor` esperando que aparezcan pantallas. Los taps individuales son rápidos. Optimizar los taps cuando los waits dominan es premature optimization.

4. **Biometric no es "gratis" de implementar en herramientas de testing.** La incapacidad de Maestro de soportar Face ID no es un bug ni un descuido — es una consecuencia de sandboxing deliberado. Herramientas que corren en sandbox JS compran portabilidad a costa de integración con el sistema operativo.

5. **La evidencia visual importa.** Los screenshots por step permiten verificar que las tres herramientas ejecutaron el mismo flujo. Sin ellos, una diferencia de 15 segundos podría explicarse como "Maestro ejecutó algo diferente". Con ellos, es evidente que el flujo es idéntico.

---

*Anterior: [Capítulo 10 — Paridad Android](10-paridad-android.md) | Siguiente: [Capitulo 12 — Permisos de accesibilidad](12-permisos-accesibilidad.md)*

*[Índice del libro](README.md)*
