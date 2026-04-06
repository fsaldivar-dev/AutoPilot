# RFC: Recorder Semántico — AutoPilot

**Estado:** Implementado (PRs #45, #47, #48)
**Fecha:** 2026-04-04 (RFC) → 2026-04-05 (implementacion)
**Área:** Captura de interacciones y replicabilidad de scripts

> **Nota post-implementacion:** Este RFC fue el diseno teorico. La implementacion real se documenta en:
> - [Capitulo 13 del libro](../libro/13-el-recorder-semantico.md) — mecanismos, resultados, comparativa
> - [Hallazgos](../recorder/HALLAZGOS.md) — limitaciones reales encontradas
> - [Bitacora](../recorder/BITACORA.md) — diario de desarrollo crudo

---

## El problema

Los recorders de automatización mobile fallan por una razón estructural: graban **dónde** ocurrió la acción, no **qué** fue accionado. Un script generado con coordenadas o XPath no es un test — es una fotografía frágil de un momento específico.

```
tapAt 375,812           ← qué pasa si el layout cambia 10px?
/XCUIElementTypeButton[2]  ← qué pasa si agregan un botón antes?
```

La consecuencia: los equipos gastan más tiempo manteniendo tests rotos que escribiendo tests nuevos. La industria documenta tasas de falla del 17-44% en scenarions reales ([arxiv 2504.20237](https://arxiv.org/html/2504.20237)), con hasta 70% de falla en selectores dependientes de UI.

---

## Comparativa teórica de herramientas

### Mecanismo de captura

| Herramienta | Cómo captura | Selector generado | Bloqueo |
|-------------|-------------|-------------------|---------|
| **Appium Inspector** | WebDriver session logs | XPath (default), Accessibility ID | Síncrono — espera respuesta del servidor Appium (~200-500ms por acción) |
| **WDA (iOS)** | XCUITest via WebDriver | NSPredicate, Class Chain, XPath | Síncrono — round-trip a WDA server (~50-200ms) |
| **Maestro Studio** | Screenshot diff + CMD+click | Text (regex), ID, coordenadas como fallback | Síncrono — screenshot compare por animación (~2000ms wait fijo) |
| **AutoPilot (teórico)** | CGEventTap pasivo (iOS) / AccessibilityEventListener (Android) | id > label único > label[N] > tapAt | **Asíncrono** — captura <1ms, resolución en background |

### Latencia por acción (teórica)

```
Appium Inspector:   ████████████████████  200-500ms
WDA:                ████████              50-200ms
Maestro Studio:     ████████████████████████████████  2000ms+ (wait fijo)
AutoPilot (teórico) █                     <1ms captura + ~100ms resolución async
```

El simulador nunca se bloquea en AutoPilot. El usuario interactúa normalmente — el script se genera en background. La resolución de 100ms aparece como autocompletar, no como espera.

---

## Análisis de replicabilidad

### Definición

**Replicabilidad** = porcentaje de veces que un script grabado se ejecuta exitosamente sin modificación, en el mismo dispositivo, misma versión de app, condiciones similares.

### Por herramienta

| Herramienta | Replicabilidad estimada | Principal causa de falla |
|-------------|------------------------|--------------------------|
| **Appium (XPath)** | 40–55% | XPath rompe con cualquier cambio estructural. Incompatibilidad de versiones de cliente. |
| **Appium (Accessibility ID)** | 65–75% | Mejor selector, pero el overhead del servidor Appium introduce flakiness por timing. |
| **WDA** | 60–70% | NSPredicate es rápido, pero el round-trip a WDA server introduce latencia no determinística. |
| **Maestro** | 70–75% | Text-based selectors son buenos. El problema es el `waitForAnimationToEnd` de 2s fijo: si la animación tarda 2.1s, falla. |
| **AutoPilot (teórico)** | **85–90%** | `waitFor` injection hace el script state-aware. UIStabilizer usa quiet-period real (no tiempo fijo). Selector: id > label > label[N]. |

### Por qué cada uno falla

**Appium (XPath):**
```xml
/XCUIElementTypeApplication/XCUIElementTypeWindow/XCUIElementTypeButton[2]
```
El desarrollador agrega un badge de notificación — el botón pasa a ser `[3]`. Script roto. Sin cambio funcional en la app.

**WDA:**
Round-trip al servidor WDA introduce latencia no determinística. En CI, un servidor bajo carga puede tardar 300ms donde en local tardaba 50ms. El `tap` llega cuando la animación aún no terminó.

**Maestro:**
```yaml
- waitForAnimationToEnd:
    timeout: 2000   # fijo
```
Si una animación de red tarda 2.3s (servidor lento en CI), el test continúa con el elemento aún animando. Falla en CI, pasa en local.

**AutoPilot (teórico):**
```auto
waitFor "Confirmar"    ← espera que el elemento EXISTA, no que pasen N ms
tap "Confirmar"
```
`waitFor` + `UIStabilizer` (quiet-period) = el script avanza cuando la UI está estable, no cuando pasó un timer. Determinístico por diseño.

---

## Por qué XPath es el problema central

XPath en mobile no es nativo. Ni XCUITest ni UIAutomator lo entienden. Cada query obliga al framework a:
1. Serializar **todo** el árbol de UI a XML
2. Evaluar el XPath sobre ese XML
3. Devolver los resultados

En apps complejas, eso toma 500ms-2s por query. Y el selector resultante es `[2]` — posición, no identidad.

**La filosofía de AutoPilot:**
> "Si el selector describe DÓNDE está algo, es frágil.  
> Si describe QUÉ es algo, es estable."

```
Frágil:   /XCUIElementTypeButton[2]
Frágil:   tapAt 375, 812
Estable:  tap "Confirmar"          ← label
Estable:  tap "loginButton"        ← accessibility id
Resiliente: tap "Confirmar[2]"     ← label + ocurrencia, si hay duplicados
```

---

## Velocidad de transmisión: latencia end-to-end

El "flujo" del recorder depende de cuánto tiempo pasa entre que el usuario toca y el script se actualiza.

### Desglose por capa

| Capa | Appium | WDA | Maestro | AutoPilot (teórico) |
|------|--------|-----|---------|---------------------|
| Captura del evento | ~5ms (session log) | ~10ms | ~16ms (60fps screenshot) | <1ms (CGEventTap / AccessibilityEvent) |
| Resolución de elemento | ~100-300ms (XPath full tree) | ~50-200ms (NSPredicate) | ~100ms (visual + tree) | <1ms (árbol cacheado) |
| Round-trip red/IPC | 50-200ms (HTTP Appium server) | 50-100ms (HTTP WDA) | 0 (local) | 0 (local) |
| Wait por animación | variable | variable | **2000ms fijo** | variable (quiet-period real) |
| **Total percibido** | **~350-700ms** | **~200-400ms** | **~2100ms** | **~100ms async** |

### Por qué Maestro Studio se siente lento

El `wait_for_animation_to_end` es la operación que Maestro usa para saber cuándo continuar. Compara screenshots consecutivos. El default es 2000ms. Cada tap espera 2 segundos. Una sesión de 20 taps = 40 segundos solo en waits. 

Esto es diseño intencional de Maestro — priorizan estabilidad sobre velocidad. El costo es que grabar se siente torpe.

### El modelo asíncrono de AutoPilot

```
t=0ms:   Usuario toca "Confirmar"
t=0ms:   CGEventTap callback dispara (captura x,y)  ← no bloquea simulador
t=0ms:   Simulador procesa el tap normalmente
t=1ms:   Background thread: busca en árbol cacheado
t=15ms:  Encuentra elemento "Confirmar" (id=confirmBtn)
t=15ms:  Script buffer: append "waitFor "Confirmar"\ntap "Confirmar""
t=15ms:  Terminal muestra: [REC] tap "Confirmar"   ← user ve feedback
t=100ms: AXObserver detecta cambio de layout
t=100ms: Cache se refresca para el próximo tap
```

El usuario **nunca espera**. El simulador procesa el tap en t=0. El script aparece en t=15ms — como autocompletar en un IDE.

---

## Replicabilidad por escenario

No todos los contextos son iguales. Estimaciones por condición:

| Escenario | Appium XPath | Maestro | AutoPilot (teórico) |
|-----------|-------------|---------|---------------------|
| Mismo dispositivo, misma versión, mismos datos | 55% | 78% | **93%** |
| Mismo dispositivo, versión minor de app | 40% | 70% | **88%** |
| Diferente dispositivo (mismo OS) | 30% | 65% | **82%** |
| CI vs local (latencias distintas) | 35% | 60% | **87%** |
| App con texto dinámico (datos de servidor) | 20% | 50% | **75%** |

El porcentaje de AutoPilot baja en "texto dinámico" porque `waitFor "Hola, Federico"` falla si el nombre cambia. La solución es usar el `identifier` en vez del label — que es lo que el selector algorithm prioriza cuando existe.

---

## Limitaciones de la solución teórica

1. **Apps sin Accessibility IDs** — Si el equipo no configura `accessibilityIdentifier` en iOS o `android:contentDescription` en Android, el selector cae a `label[N]`, que es más frágil que un ID pero mejor que XPath.

2. **Contenido completamente dinámico** — Listas de productos, feeds, buscadores. El label "iPhone 15 Pro 256GB $1,299" no es un selector estable. Requiere que el QA edite el script post-grabación.

3. **Scroll-to-element** — Si el elemento no está en pantalla, `waitFor` detectará que no existe. Se necesita `scroll` antes. El recorder podría detectar el intento de tap fuera del viewport y emitir `scroll` automáticamente.

4. **Polling vs streaming (Android)** — El modelo actual de polling cada 200ms puede perder eventos en interacciones muy rápidas (<200ms entre taps). Solución v2: socket persistente con event push.

---

## Conclusión

La diferencia fundamental entre AutoPilot y las herramientas existentes no es de velocidad — es de **arquitectura de selectores** combinada con **waits inteligentes**:

```
Grabadores actuales:  coordenadas/XPath + timers fijos = frágil + lento
AutoPilot (teórico):  id/label semántico + state-aware wait = estable + fluido
```

El 85-90% de replicabilidad teórico frente al 40-75% de los tools existentes viene de dos decisiones:
1. Nunca generar XPath — siempre resolver a identidad semántica
2. `waitFor` injection — el script espera estado, no tiempo

---

## Nuestra propia fragilidad — evaluación honesta

Antes de criticar a Maestro y Appium, hay que ser brutales con AutoPilot. El RFC sería deshonesto si no documentara los problemas propios.

### `label[N]` es XPath con mejor nombre

```auto
tap "Camera[2]"
```

Esto describe POSICIÓN, no IDENTIDAD. Es `XCUIElementTypeButton[2]` con mejor presentación. Si el desarrollador agrega un elemento "Camera" antes en el layout, `Camera[2]` ahora tapa el elemento equivocado — **sin error, sin warning, silenciosamente**. El test "pasa" haciendo la acción incorrecta.

Maestro tiene el mismo problema con su `index` selector. Appium lo tiene con XPath. Nosotros lo tenemos con `[N]`.

### `waitFor "texto"` es tan frágil como el texto del botón

```auto
waitFor "Iniciar sesión"
tap "Iniciar sesión"
```

Si el equipo de producto cambia el copy a "Entrar", si la app está en inglés en CI, si hay un A/B test activo — el script rompe. Criticamos a Maestro por hardcodear `"Allow"` en inglés. Nosotros hardcodeamos `"Iniciar sesión"`. Es el mismo problema con distinto nombre.

### No verificamos rol del elemento

```auto
tap "Submit"
```

Puede tocar un `AXStaticText` con texto "Submit" que no es un botón interactivo. La acción llega al elemento, no hace nada visible, el test continúa. **Falso positivo silencioso.**

### El oracle es débil

```auto
tap "Guardar"
waitFor "Dashboard"
```

`waitFor "Dashboard"` confirma que el string "Dashboard" existe en algún lugar de la pantalla. No confirma:
- Que no hay un error silencioso debajo del fold
- Que es el Dashboard correcto (si hay múltiples contextos)
- Que los datos se guardaron realmente
- Que la UI está en el estado esperado y no en un estado de loading parcial

### `identifier` requiere disciplina del equipo

Si el developer no configura `accessibilityIdentifier` (iOS) o `android:contentDescription` (Android), el selector priority cae a `label[N]`. En la práctica, la mayoría de los equipos NO configuran accessibility IDs porque no están construyendo apps para screen readers — están construyendo features. El selector "estable" que asumimos como default en realidad es el frágil.

### Sin contexto — selectores globales en pantallas complejas

```auto
tap "Confirmar"
```

Si hay tres botones "Confirmar" en pantalla (en tres secciones distintas), `Confirmar[2]` no es estable. No hay forma de decir "el Confirmar dentro de la sección de Pago". El scope es siempre global.

---

## Cómo mejorar nuestra fragilidad — propuestas técnicas

### 1. Multi-attribute fingerprinting (la más importante)

En lugar de guardar UN selector, guardar un fingerprint completo al momento de grabar:

```
# Grabado en record:
tap "Camera"
# fingerprint: role=AXButton, label="Camera", id="cameraBtn", parent=AXCell, siblings=3, pos_in_parent=2

# Al replay, matching por score:
# id="cameraBtn" encontrado → 100% match → usar este
# id no encontrado → buscar role=AXButton + label="Camera" → 80% match
# label no único → usar pos_in_parent=2 DENTRO del mismo parent → 60% match
# nada encontrado → fallback a tapAt con warning
```

El script sigue siendo legible (`tap "Camera"`), pero el engine tiene múltiples atributos para encontrar el elemento correcto si el primero falla. Esto es lo que hacen los self-healing tools como Autonoma — la diferencia es que lo hacemos transparente y offline, sin AI.

### 2. Context anchoring — scope de búsqueda

```auto
tap "Confirmar" within "Sección de Pago"
tap "Camera" within "Galería"
```

`within` limita la búsqueda al subtree del elemento padre. `Camera[2]` en la galería deja de ser frágil si hay un identificador estable para "Galería".

Internamente: buscar el ancestor con label/id = "Galería", luego buscar "Camera" dentro de ese subtree. Si hay un solo "Camera" dentro de "Galería", `[N]` no es necesario.

### 3. Role verification

```auto
tap[button] "Submit"        # solo toca AXButton con label Submit
tap[textfield] "Email"      # solo toca AXTextField
scroll[list] "Productos"    # solo scrollea AXScrollArea / AXList
```

El recorder detecta el rol al grabar y lo embebe en el comando. Al reproducir, si el elemento encontrado tiene rol diferente — falla con mensaje claro en vez de tocar el elemento equivocado.

### 4. `waitUntilGone` como primitiva de primera clase (ya mencionado)

```auto
tap "Guardar"
waitUntilGone "Guardando..."    # espera que el loader desaparezca
waitFor "Guardado"              # confirma el estado final
```

Esto no es solo timing — es el oracle más barato disponible. Confirma que la operación terminó (el loader se fue) Y que el resultado esperado llegó (el mensaje de éxito apareció).

### 5. OCR — cuándo ayuda y cuándo no

OCR lee texto de screenshots. Herramientas como `tesseract` o `Vision.framework` (Apple, disponible en macOS sin dependencias externas).

**Cuándo OCR resuelve problemas reales:**
- Elementos en Canvas o SpriteKit (videojuegos, drawing apps) — no tienen árbol AX
- WebView con contenido no expuesto en AX
- Custom views que no configuraron accessibility
- Validar que un número/precio específico aparece en pantalla (oracle)

```auto
assertOCR contains "$ 1,299.00"    # verifica el precio exacto, no el label del elemento
assertOCR contains "Error"         # detecta cualquier texto de error en pantalla
```

**Cuándo OCR NO ayuda:**
- Como selector para tap — OCR da coordenadas del texto, no del elemento interactivo. El texto "Submit" puede estar dentro de un botón con padding, y el OCR te da las coords del texto, no del tap target. Toca el texto pero no el área reactiva del botón.
- Para elementos sin texto visible (íconos, imágenes)
- Rendimiento — screenshot + OCR ~200-500ms por check vs ~5ms con AX tree

**Conclusión sobre OCR:** Útil como ORACLE (assert), no como selector para tap. El flujo correcto:
```auto
tap "submitButton"          ← selector AX (rápido, confiable para tap)
assertOCR "Operación exitosa"  ← OCR para verificar el resultado (flexible, no necesita ID)
```

### 6. Perceptual hash para verificación visual

No comparación de pixel a pixel (demasiado frágil — cualquier rendering mínimo lo rompe). Un perceptual hash (pHash) da un fingerprint de la "semejanza visual" de la pantalla.

```auto
tap "Guardar"
assertScreen "post-guardar"  # compara pHash contra baseline capturado en el record
```

Si la pantalla post-guardar luce diferente en más de N% → test falla para revisión manual. Si luce igual → test pasa.

**Trade-off:** Los pHashes son frágiles a cambios legítimos de UI (rediseño de pantalla). Útiles como canary, no como gate obligatorio.

### 7. La solución real a `Camera[2]`

El problema de `Camera[2]` se resuelve con context anchoring + role verification:

```auto
# Frágil:
tap "Camera[2]"

# Robusto:
tap[button] "Camera" within "Filtros de cámara"
# → busca AXButton con label "Camera" dentro del subtree de "Filtros de cámara"
# → si hay uno solo dentro del contexto, no necesita [N]
# → si hay varios, [N] dentro del contexto es más estable que [N] en toda la pantalla
```

Si el developer configuró IDs:
```auto
tap "frontCameraButton"    # ← identifier estable, inmune a todo
```

La solución real es que los developers configuren accessibility IDs en elementos críticos. El recorder puede detectar cuándo un elemento no tiene ID y **marcar el paso con un warning**:
```
[REC] tap "Camera[2]"   ⚠️  no tiene accessibilityIdentifier — frágil
[REC] tap "loginBtn"    ✅  tiene identifier estable
```

---

## Mapa de fragilidad honesto — AutoPilot vs competencia

| Escenario | Appium | Maestro | AutoPilot hoy | AutoPilot mejorado |
|-----------|--------|---------|---------------|-------------------|
| Elemento con ID estable | ✅ | ✅ | ✅ | ✅ |
| Elemento sin ID, texto único | ⚠️ | ✅ | ✅ | ✅ |
| Elemento sin ID, texto duplicado | ❌ XPath posicional | ⚠️ index posicional | ⚠️ label[N] posicional | ✅ context anchoring |
| Cambio de copy / A/B test | ❌ | ❌ | ❌ | ⚠️ fingerprint mitiga |
| Locale diferente | ❌ | ❌ | ⚠️ si usa texto | ✅ si usa identifier |
| Elemento sin accessibility configurada | ❌ XPath | ⚠️ text fallback | ⚠️ label[N] | ✅ OCR como oracle |
| Verificación de resultado (oracle) | ⚠️ assert básico | ⚠️ assert básico | ❌ no existe hoy | ✅ assertOCR / assertScreen |
| Tap en elemento incorrecto silencioso | ✅ falla | ✅ falla | ❌ puede pasar silencioso | ✅ role verification |
| Scroll en UIKit/SwiftUI custom | ❌ | ❌ | ✅ CGEvent | ✅ CGEvent |
| CI sin servidor intermediario | ❌ | ❌ | ✅ | ✅ |

**La columna más honesta es "AutoPilot hoy"** — tenemos ventajas reales en scroll, permisos y CI, pero compartimos la fragilidad de posición y texto con todos los demás. La columna "mejorado" es el roadmap.

---

## Taxonomía de fallas: por qué los tests rompen

> **Principio base:** Un test debe pasar siempre o fallar siempre. Un test que a veces pasa y a veces falla no es un test — es una lotería. Es peor que no tener test porque genera falsa confianza.
> — Martin Fowler, *Eradicating Non-Determinism in Tests*

La investigación de Google (2017) y estudios académicos recientes identifican que el **45% del flakiness** viene de una sola causa (timing), pero el 55% restante es heterogéneo. Aquí la taxonomía completa con su solución en AutoPilot:

---

### Categoría 1: Timing y sincronización (45% de los fallos)

**El problema:**
```swift
Thread.sleep(2000)   // Maestro, Appium: esperar animación
tapAt(375, 812)      // El elemento aún no cargó
```
Si la red está lenta, la animación tarda 2.1s. El test continúa a los 2.0s. Tap en el vacío.

**Por qué es el más común:** Los tests escritos en local con red rápida usan `sleep(500)`. En CI con red lenta, ese mismo 500ms es insuficiente.

**Solución en AutoPilot:**
```auto
waitFor "Dashboard"        ← espera que el elemento EXISTA (state-based)
waitUntilGone "Cargando"   ← espera que el loader DESAPAREZCA
```
No hay timer. El script avanza cuando la UI está en el estado esperado, sin importar cuánto tarde. Latencia de red alta → el test simplemente espera más. **Determinístico.**

---

### Categoría 2: Selectores frágiles (>70% de las roturas de scripts)

**El problema:**
```
/XCUIElementTypeButton[2]     ← el desarrollador agrega un badge → pasa a [3]
tapAt 375, 812                ← rediseñan el layout → el botón se movió
```

**La raíz:** XPath describe DÓNDE está algo, no QUÉ es algo. Cualquier cambio estructural en el árbol de UI invalida el selector — sin cambio funcional en la app.

**Solución en AutoPilot:**
```
Prioridad de selector:
1. identifier (accessibilityId)   → estable, set por el dev, no cambia con refactors
2. label único en pantalla        → "Iniciar sesión" — estable si el texto no cambia
3. label[N] — ocurrencia          → "Confirmar[2]" — estable si el orden no cambia
4. tapAt x,y                      → último recurso, con comentario # no-semantic
```

`identifier` es inmune a rediseños visuales. El botón puede moverse, cambiar de color, cambiar su texto visible — el `accessibilityIdentifier` no cambia. **Un selector que describe QUÉ es algo siempre es más estable que uno que describe DÓNDE está.**

---

### Categoría 3: Dependencia de estado (12% de los fallos)

**El problema:** Tests que pasan si se corren en orden pero fallan en aislamiento.

```
Test A: hace login     → deja sesión activa
Test B: toca "Perfil"  → asume sesión activa de Test A
Test B solo: falla     → no hay sesión
```

**La raíz:** Estado compartido entre tests. Si Test A corre antes, Test B "hereda" el estado. Esto es un contaminador oculto — el test no prueba lo que crees que prueba.

**Solución en AutoPilot:**
Cada script `.auto` debe empezar desde estado conocido:
```auto
terminate com.example.app     ← mata cualquier instancia
launch com.example.app        ← inicia desde cero
waitFor "Pantalla de login"   ← confirma estado inicial
```
El recorder emite `terminate` + `launch` al inicio de cada sesión grabada. **Aislamiento por diseño.**

---

### Categoría 4: Diferencias de entorno — CI vs local

**El problema:** El test pasa en tu Mac, falla en el runner de GitHub Actions.

Causas documentadas:
- CI tiene CPU más lento → animaciones tardan más → `sleep(500)` insuficiente
- CI tiene red diferente → APIs responden más lento → loaders duran más
- Versión de Xcode/Android SDK diferente en CI → comportamiento de UI distinto
- Variables de entorno faltantes → app en estado diferente

**Solución en AutoPilot:**
`waitFor` / `waitUntilGone` absorben todas las diferencias de timing de entorno. Si CI es 3x más lento, los tests simplemente esperan 3x más — sin fallar. El estado de la UI es el gatillo, no el reloj.

Para diferencias de SDK: `auto config device` + versión fijada en `.autopilot`.

---

### Categoría 5: Interrupciones del sistema

**El problema:** El test está corriendo y aparece:
- Diálogo de permiso de cámara
- Alerta de batería baja
- Notificación push de otra app
- Actualización del sistema
- FaceID / Touch ID prompt

El test tap al diálogo sin saber qué es. O peor: el diálogo bloquea el elemento que el test quería tocar.

**Solución en AutoPilot — 3 niveles:**

**Nivel 1: Pre-grant en setup**
```auto
permission grant camera com.example.app
permission grant microphone com.example.app
permission grant notifications com.example.app
```
Concede todos los permisos antes de correr el test. El diálogo nunca aparece.

**Nivel 2: Detection en el recorder**
El recorder detecta system dialogs por su estructura conocida (título "Permitir acceso a…", botones "Permitir" / "No permitir") y emite `permission grant` en vez de `tap "Permitir"`. El `permission grant` es idempotente — no falla si ya fue concedido.

**Nivel 3: `waitFor` como guardia**
```auto
tap "Tomar foto"
waitFor "Vista de cámara"   ← si aparece diálogo de permiso, el waitFor no va a pasar
                             ← el test falla con mensaje claro: "timeout esperando Vista de cámara"
                             ← no falla silenciosamente con tap en posición equivocada
```
**Falla claramente, no silenciosamente.** Un test que falla con mensaje claro es mejor que uno que "pasa" por razones equivocadas.

---

### Categoría 6: A/B testing y feature flags

**El problema:**
```
Botón dice "Continuar" en grupo A
Botón dice "Siguiente" en grupo B
```
El script graba `tap "Continuar"`. En grupo B, el elemento no existe. Falla.

**Variante más peligrosa:** El flag cambia la estructura de la UI — agrega un paso intermedio, reordena elementos. El script graba una ruta que solo existe para el 50% de los usuarios.

**Solución en AutoPilot:**
- **Preferir `identifier`** — `tap "nextStepButton"` funciona en ambos grupos si el dev mantiene el mismo ID
- **Detectar en el recorder** — Si el elemento tiene `identifier`, usar eso en vez del label visible
- **Documentar en el script** — El recorder puede agregar comentario automático:
  ```auto
  tap "nextStepButton"   # label="Continuar" (puede variar por A/B test)
  ```

Para flags que cambian la estructura completa del flujo: necesitas scripts separados por variante. No hay solución técnica a un flujo fundamentalmente diferente.

---

### Categoría 7: Teclado, autocorrect y texto predictivo

**El problema:**
```auto
type "hello world"
```
El autocorrect cambia "hello" a "Hello" (mayúscula automática). O cambia "mundo" a "Mundo". La aserción `exists "hello world"` falla.

**Variante peor:** El texto predictivo completa la palabra antes de que el comando `type` termine. El resultado en el campo es diferente al texto que se intentó escribir.

**Solución en AutoPilot:**
- `clear` antes de `type` — limpia el campo y desactiva el estado de autocorrect
- `type` via inyección de teclado de bajo nivel (CGEvent en iOS, `UiAutomation.setText()` en Android) — bypassa el autocorrect completamente
- El recorder detecta que el elemento es `AXTextField` y emite:
  ```auto
  tap "Email"
  clear "Email"      ← limpia estado previo y autocorrect
  type "user@test.com"
  ```

---

### Categoría 8: El problema del oráculo — ¿el test pasó por las razones correctas?

**El problema:** Un test puede "pasar" sin validar nada real.

```auto
tap "Guardar"
# ← el test termina aquí. ¿Se guardó? ¿Hubo error silencioso?
```

Sin aserción post-acción, el test pasa aunque la operación haya fallado — si la app no muestra error visible.

**Variante:** El test pasa porque el estado fue dejado por el test anterior. Corre en aislamiento y falla. El "pass" no era real.

**Solución en AutoPilot:**
```auto
tap "Guardar"
waitFor "Guardado exitosamente"    ← aserción de estado esperado
# ó
waitUntilGone "Guardando..."       ← confirma que la operación terminó
exists "Error"                     ← verifica que NO hay error
screenshot guardado.png            ← evidencia del estado final
```

El recorder puede sugerir automáticamente `waitFor` después de cada tap en botón de submit/guardar — detectado por patrones de label ("Guardar", "Confirmar", "Enviar", "Submit", "Save").

---

### Mapa de cobertura: AutoPilot vs causas de falla

| Causa | Frecuencia | AutoPilot lo cubre | Mecanismo |
|-------|-----------|-------------------|-----------|
| Timing / async | 45% | ✅ completo | `waitFor` + `waitUntilGone` + UIStabilizer |
| Selectores frágiles | >70% roturas | ✅ completo | id > label > label[N], nunca XPath |
| Dependencia de estado | 12% | ✅ completo | `terminate` + `launch` al inicio |
| CI vs local | alta | ✅ completo | State-based waits, sin timers fijos |
| System dialogs | media | ✅ mayormente | `permission grant` idempotente |
| A/B / feature flags | variable | ⚠️ parcial | `identifier` cuando existe |
| Autocorrect / teclado | baja | ✅ completo | `clear` + inyección de bajo nivel |
| Oráculo débil | alta | ⚠️ parcial | Sugerencia de `waitFor` post-acción |
| Contenido dinámico | alta | ⚠️ parcial | Requiere `identifier` en vez de texto |
| Device fragmentation | 34% device-specific | ⚠️ mitiga | Selector semántico cross-device |

**⚠️ parcial** = el diseño lo mitiga pero no elimina. El 1% restante de fallas viene de contenido verdaderamente dinámico (precios, fechas, datos de servidor) que ningún recorder puede manejar sin que el QA edite el script post-grabación.

---

## Issues reales: Maestro, Appium y Autonoma AI

Investigación de issues reportados en GitHub, foros y documentación oficial. Clasificados por categoría con número de issue donde aplica.

---

### Timing y animaciones

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| #1703 | Maestro | Flakiness en transiciones entre pantallas (~60% usuarios) | XCTest/UiAutomator no exponen estado de animación | ✅ `waitUntilGone` del elemento anterior |
| #1477 | Maestro | `waitForAnimationToEnd` termina antes de tiempo O nunca termina (15s timeout) | Detección de animación por inferencia de jerarquía, no por evento real | ✅ UIStabilizer quiet-period (evento real, no timer) |
| #2843 | Maestro | `waitForAnimationToEnd` ignora el timeout configurado | Implementación ignora el parámetro | ✅ No aplica — usamos evento de estabilidad |
| #3868 | Appium Android | Animaciones del sistema causan flakiness — **issue abierto desde 2014, sin fix** | UiAutomator no tiene mecanismo de detección de idle confiable | ✅ `waitUntilGone` del loader |
| #12707 | Appium Android | Touch release tarda 1000ms+ (vs 100ms en UiAutomator1) | Regresión de performance en UiAutomator2 | ✅ AutoPilot usa inyección directa CGEvent / UiAutomation.injectInputEvent |
| #15829 | Appium Android | Test de 2min se volvió 9-11min entre versiones 4.21→4.22 | Regresión interna sin documentar | ✅ No hay servidor intermediario — directo a dispositivo |

**Patrón común:** Todas las herramientas usan timers fijos o detección por comparación de screenshots. AutoPilot usa `kAXLayoutChangedNotification` (iOS) y `TYPE_WINDOW_CONTENT_CHANGED` (Android) — eventos reales de estabilidad.

---

### Selección de elementos y AX tree

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| #2397 | Maestro | `assertVisible` con id + text combinados falla en iOS | XCTest no filtra correctamente con selectores combinados | ✅ Un selector a la vez, prioridad clara |
| #1409 | Maestro | `tapOn "text"` falla cuando existe `accessibilityLabel` | XCTest prioriza accessibilityLabel sobre text | ✅ AutoPilot busca en label Y title Y identifier |
| #1275 | Maestro | Elementos fuera del viewport se tratan como visibles | API de accesibilidad reporta visibilidad relativa a pantalla, no al scroll container | ⚠️ Mismo problema potencial |
| #1056 | Maestro | Botones no encontrados intermitentemente por ID o texto (~20% runs) | Race condition entre render de UI y traversal del árbol | ✅ `waitFor` antes de cada acción — el árbol se lee cuando la UI está estable |
| #20624 | Appium Android | UiAutomator2 no reconoce el mismo elemento post-navegación | Bug de caché interno de UIAutomator2 | ✅ Tree se re-fetcha en cada comando, sin caché stale |
| #18081 | Appium Android | Jetpack Compose: elementos no encontrables sin prefijo completo del resource-id | Compose usa Semantics nodes, no Views Android estándar | ⚠️ Mismo límite — requiere `testTag` + `testTagsAsResourceId` |
| #1677 | Maestro | `containsDescendants` no funciona en iOS | XCTest no expone relaciones descendant correctamente | ✅ AutoPilot busca recursivamente en todo el árbol |

---

### Scroll y gestos (incluyendo UIKit/SwiftUI mixto)

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| #2201 | Maestro | Scroll falla completamente en ciertos layouts | Detección de scroll depende de patrones específicos de jerarquía de vistas | ✅ `swipe` usa CGEvent — no depende de AXScrollable |
| #1135 | Maestro | Scroll falla en React Native iOS | RN view hierarchy incompatible con XCTest scroll detection | ✅ CGEvent swipe es agnóstico al framework |
| #2251 | Maestro | Scroll falla con Expo BlurView en Xcode 16+ | BlurView intercepta scroll events | ✅ CGEvent bypassea la jerarquía de vistas |
| #11482 | Appium iOS | Scroll no funciona en apps nativas ni WebViews | XCTest scroll API no funciona fuera de contexto nativo | ✅ `swipe` / `dragCoordinates` no usa XCTest scroll |
| — | **UIKit/SwiftUI** | Tabla con scroll deshabilitado en AX: `AXScrollable=false` en el wrapper SwiftUI, scroll real vive en UITableView subyacente. Tap en el área primero activa el foco, luego scroll funciona | SwiftUI wrapper no propaga `AXScrollable` del UITableView envuelto | ✅ `swipe up` con coordenadas en el área de contenido — no necesita AXScrollable |
| #1960 | Maestro | Swipe con coordenadas porcentuales falla en Android (especialmente tab 3+) | Translación de coordenadas iOS ≠ Android | ✅ Coordenadas absolutas en AutoPilot |

**El punto clave del scroll:** Maestro y Appium intentan hacer scroll via la API de accesibilidad (`AXScroll`, UIAutomator scroll). Si el elemento no dice `AXScrollable=true`, no scrollean. AutoPilot usa `CGEvent` (iOS) y `adb input swipe` / `UiAutomation.injectInputEvent` (Android) — gestos de bajo nivel que funcionan independientemente de lo que el árbol de accesibilidad diga.

---

### Teclado e input de texto

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| #395 | Maestro | Caracteres se pierden al escribir (~15% en dispositivos lentos) | Escritura asíncrona; UIAutomator/XCTest dropean eventos de teclado bajo carga | ✅ CGEvent keyboard (iOS) / `UiAutomation.setText()` (Android) — síncrono |
| #1061 | Maestro | `inputText` falla en campos `secureTextEntry` — aparece "Strong Password" | iOS XCTest restringe automatización en campos de contraseña | ⚠️ Mismo límite de Apple |
| #2187 | Maestro | Teclados custom: "Keyboard not presented within 1 second timeout" | XCTest solo reconoce teclado del sistema | ⚠️ Mismo límite |
| #1220 | Maestro | `hideKeyboard` falla aleatoriamente en iOS (~30%) | iOS no tiene API nativa para ocultar teclado; Maestro usa scroll como workaround | ✅ AutoPilot usa `tap` en área fuera del teclado — más confiable |
| #19245 | Appium iOS | Escritura de texto lenta — timeout hardcodeado de 1 segundo en WebDriverAgent | WDA espera 1s entre caracteres por diseño | ✅ CGEvent keyboard no tiene ese timeout |
| #8004 | Appium iOS | Texto no escribe cuando el teclado numérico está activo | XCTest no maneja correctamente la transición al teclado numérico | ✅ AutoPilot detecta el tipo de teclado activo |
| — | General | Autocorrect cambia el texto escrito — `type "hello"` resulta en `"Hello"` | Autocorrect actúa después del evento `input` | ✅ `clear` previo + inyección de bajo nivel bypassa autocorrect |

---

### Permisos y diálogos del sistema

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| #2654 | Maestro | Diálogos de permiso solo se dimisian en locale inglés | Texto de botones hardcodeado en inglés | ✅ `simctl privacy` no toca la UI — es una API de sistema, locale-agnostic |
| #2103 | Maestro | El simulador se bloquea al configurar permisos de notificación (~50% runs) | Conflicto de secuencia entre applesimutils y el state machine de permisos iOS | ✅ `simctl privacy` no usa applesimutils |
| #1463 | Maestro | Permisos de ubicación no funcionan en iOS 17 | iOS 17 cambió estructura del diálogo; botones con IDs distintos | ✅ `simctl privacy` es API de OS, no toca UI del diálogo |
| #17169 | Appium Android | `autoGrantPermissions` falla en Android 12+ | Android 12 cambió el diálogo de permisos | ✅ `adb shell pm grant` — API directa, no UI |
| #19908 | Appium iOS | No puede interactuar con diálogo de permiso de paste | Diálogo de paste no está en el árbol AX estándar | ✅ `permission grant` previamente en setup — el diálogo nunca aparece |
| #10678 | Appium Android | `autoGrantPermissions` no funciona en v1.8.0+ | Bug de regresión sin fix oficial | ✅ `adb shell pm grant` — no depende de `autoGrantPermissions` |

**Patrón común:** Maestro y Appium intentan interactuar con la UI del diálogo de permiso (tap en "Permitir"). Si el texto del botón cambia (iOS update, locale diferente), falla. AutoPilot usa `simctl privacy` (iOS) y `adb shell pm grant` (Android) — APIs de sistema que no dependen del texto del botón ni del locale.

---

### WebView y componentes custom

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| #2293 | Maestro | Elementos por ID no reconocidos dentro de WebView | XCTest y UiAutomator no traversan el DOM del WebView por default | ⚠️ Mismo límite fundamental |
| #2735 | Maestro | Browser externo (Safari/Chrome) completamente inaccesible | Proceso externo — accessibility APIs no cruzan procesos | ⚠️ Mismo límite |
| #1804 | Maestro | `data-testid` de React no detectado en WebView | DOM no expuesto, solo árbol AX de alto nivel visible | ⚠️ Mismo límite |
| — | Appium iOS | SwiftUI: soporte documentado muy limitado; gestos custom requieren coordenadas absolutas | XCTest no expone well SwiftUI gesture recognizers | ✅ CGEvent funciona sobre cualquier área de la pantalla |
| — | General | UIKit wrapped en SwiftUI: `AXScrollable=false` en wrapper aunque UITableView interno sí scrollea | SwiftUI no propaga propiedades de accesibilidad del UIViewRepresentable correctamente | ✅ `swipe` / `dragCoordinates` — CGEvent directo, sin AX |

**Límite honesto:** WebView es el punto ciego de todos los tools. Ninguno traversa el DOM de WKWebView (iOS) o WebView (Android) de forma confiable sin configuración especial (Chrome DevTools Protocol en Android). AutoPilot tiene el mismo límite.

---

### CI/CD y entorno

| Issue | Herramienta | Descripción | Causa raíz | AutoPilot |
|-------|-------------|-------------|------------|-----------|
| **#2906** | Maestro | **Completamente roto en macOS Sequoia + Xcode 16.2** — driver nunca arranca, cuelga indefinidamente | Xcode 16.2 cambió el protocolo de comunicación del driver | ✅ AutoPilot es binario Swift nativo — sin servidor intermediario que romper |
| #965 | Maestro | Driver Android no arranca en tiempo en GitHub Actions | Runners con recursos compartidos — timeout de 60s insuficiente | ✅ Sin driver proceso separado — el binario `auto` ES el driver |
| #1577 | Maestro | iOS driver no comunica en Azure CI con Node | Aislamiento de proceso Node rompe socket con el driver | ✅ Sin sockets intermediarios |
| #1776 | Maestro | Tests iOS fallan con sharding paralelo — conflictos de puerto | XCTest no soporta ejecución verdaderamente concurrente | ✅ Cada proceso `auto` es independiente — sin conflictos de puerto |
| — | Appium Android | Docker require aceleración hardware x86 — no funciona en GitHub Actions genérico | Emulador Android necesita KVM o Hypervisor | ⚠️ Mismo límite de infraestructura — no es del tool |

**El issue #2906 es crítico:** Maestro está completamente roto en macOS Sequoia + Xcode 16.2 hoy. AutoPilot no tiene este problema porque es un binario Swift que habla directamente con las APIs del OS — sin servidor JVM, sin WebDriverAgent en puerto HTTP, sin protocolo de comunicación que pueda cambiar entre versiones de Xcode.

---

### Autonoma AI — análisis de postura

Autonoma no tiene issues públicos (repositorio cerrado). Sus claims:
- "0 horas de mantenimiento" — self-healing via AI
- Sobrevive cambios de UI sin reescribir tests
- Detecta bugs visuales que automatización tradicional no ve

**Lo que no documenta:**
- Cómo maneja WebView (mismo límite que todos)
- Cómo maneja gestos complejos (scroll en UIKit/SwiftUI mixto)
- Qué pasa cuando el AI "decide" que un test pasó — el problema del oráculo
- Latencia por acción (el AI necesita analizar screenshots — probablemente lento)
- Funcionamiento offline / sin LLM disponible

**El problema del self-healing:** Si la UI cambia y el test "se cura" automáticamente, ¿cómo sabes que el test sigue validando lo que debe validar? Un botón puede moverse de lugar y el AI lo encuentra — pero si el botón desapareció por un bug, el AI no lo encuentra y el test falla. La línea entre "adaptación legítima" y "enmascaramiento de bug real" es ambigua por diseño.

---

### Tabla maestra: cobertura de issues por herramienta

| Categoría | Maestro | Appium | Autonoma | **AutoPilot (teórico)** |
|-----------|---------|--------|----------|------------------------|
| Timing / animaciones | ❌ timer fijo, detección frágil | ❌ issue 10 años sin fix | ❓ black box | ✅ evento real de estabilidad |
| Scroll en vistas custom / UIKit-SwiftUI | ❌ depende de AXScrollable | ❌ depende de AXScrollable | ❓ | ✅ CGEvent directo |
| Permisos (locale, iOS version) | ❌ texto UI hardcodeado en inglés | ❌ rompe con cada versión Android | ❓ | ✅ simctl / adb pm — API de sistema |
| Teclado y caracteres perdidos | ❌ async, dropea caracteres | ❌ 1s timeout hardcodeado en WDA | ❓ | ✅ CGEvent síncrono |
| CI sin servidor intermediario | ❌ driver JVM separado, rompe con Xcode | ❌ WebDriverAgent HTTP server | ❓ cloud only | ✅ binario standalone |
| Xcode 16.2 / macOS Sequoia | ❌ **completamente roto** (#2906) | ❌ problemas de compatibilidad | ❓ | ✅ binario nativo Swift |
| WebView / DOM | ❌ no traversa | ❌ no traversa | ❓ | ❌ mismo límite |
| Jetpack Compose | ❌ necesita anotaciones | ❌ necesita testTag | ❓ | ❌ mismo límite |
| Selectores locale-agnostic | ❌ texto UI dependiente de idioma | ❌ texto UI dependiente | ❓ | ✅ identifier primero |
| Parallel execution | ❌ roto en iOS y Android | ❌ conflictos de puerto | ❓ | ✅ procesos independientes |

---

## Estado de implementacion (2026-04-05)

### Propuestas del RFC: que se implemento

| # | Propuesta | Estado | Notas |
|---|-----------|--------|-------|
| 1 | Multi-attribute fingerprinting | **SI** | Cascada id > title > label > label[N] > tapAt. No guarda fingerprint completo como sidecar. |
| 2 | Context anchoring (within) | **SI** | `tap "X" within "Y"`. Android filtra containers genericos (`android:id/*`). |
| 3 | Role verification ([button]) | **SI** | `tap[button] "X"`. Desambigua TextViews vs Buttons. |
| 4 | waitUntilGone | **NO** | Solo `waitFor` (aparicion). Falta deteccion de desaparicion. |
| 5 | OCR (assertOCR) | **NO** | Sin integracion con Vision.framework ni tesseract. |
| 6 | Perceptual hash (assertScreen) | **NO** | Sin captura de screenshots ni diff visual. |
| 7 | CGEventTap pasivo (iOS) | **SI** | `AutoLibiOS/EventRecorder.swift` — `.listenOnly`, window frame filter, thread dedicado |
| 8 | getevent (Android) | **SI** | `AutoCore/GetEventParser.swift` + `AndroidRecordingSession.swift` — calibracion touchscreen |
| 9 | Selector priority | **SI** | `AutoLibiOS/SemanticResolver.swift:chooseBestSelector()` + `AutoCore/AndroidSemanticResolver.swift` |
| 10 | waitFor injection | **SI** | `AutoCore/ScriptGenerator.swift:24-43` — 3 triggers + soporte `[N]` |
| 11 | terminate+launch | **SI** | `AutoLibiOS/RecordingSession.swift:45` (config) + `AutoCore/AndroidRecordingSession.swift:49` (dumpsys) |
| 12 | System dialog detection | **PARCIAL** | `AutoLibiOS/RecordingSession.swift:361-424` — solo iOS, detecta AXSheet/AXDialog |
| 13 | Keyboard recording | **PARCIAL** | `AutoLibiOS/RecordingSession.swift:192-237` — solo iOS, CGEventTap keyDown + debounce |
| 14 | Long press | **SI** | `RecordingSession.swift:164` + `AndroidRecordingSession.swift:200` — threshold 0.5s |
| 15 | Double tap | **SI** | `RecordingSession.swift:132` + `AndroidRecordingSession.swift:233` — buffer 300ms |
| 16 | Scroll detection | **PARCIAL** | iOS: NO (#50). Android: `AndroidRecordingSession.swift:217` (swipe >50px) |
| 17 | scrollTo visibility | **NO** | Issue #49. `search()` encuentra offscreen. Fix propuesto: #58 |

**Implementado: 11/17 completo, 3/17 parcial, 3/17 pendiente.**

### Descubrimientos no previstos por el RFC

| Descubrimiento | Impacto |
|----------------|---------|
| mouseUp no llega via CGEventTap (PID filtering) | Resolver en mouseDown, no esperar mouseUp |
| AXUIElementCopyElementAtPosition no funciona en Simulator | Hit-test manual recursivo del AX tree |
| findSimulatorContent() llama activate() que cambia el focus | `findSimulatorContentFast()` sin activate |
| Compose Button sin label (TextView tiene texto, Button tiene click) | `findClickableFrame()` busca Button padre |
| getevent calibracion parsea 0037 como Y en vez de 0036 | Parseo estricto con hasPrefix |
| `adb input tap` NO genera getevent | Solo toques reales del emulador window generan eventos kernel |
| AX tree incluye elementos offscreen | scrollTo falla silenciosamente |
| waitFor "X[2]" buscaba literal | CommandDispatcher ahora parsea [N] y espera N+ matches |

### Resultados vs predicciones del RFC

| Metrica | RFC predijo | Resultado real |
|---------|------------|----------------|
| Latencia captura | <1ms | <1ms iOS, <5ms Android |
| Replicabilidad | 85-90% | 100% (editado), 0% (raw — scroll) |
| Selectores semanticos | alta prioridad a id | 64-79% semanticos, 21-36% tapAt |
| Bloqueo del device | No | No (`.listenOnly` / getevent pasivo) |

La prediccion de 85-90% asumia que el recorder generaria scripts perfectos. La realidad: el script necesita 1-2 ediciones manuales (scroll) para llegar a 100%. Sin ediciones: 0% porque el scroll es el ultimo problema.

---

## Comparativa real: AutoPilot recorder vs industria (2026-04-05)

Basada en implementacion real, no predicciones.

### Velocidad de captura (medida)

| Herramienta | Latencia captura | Latencia tree | Bloqueo | Total percibido |
|-------------|-----------------|---------------|---------|-----------------|
| **AutoPilot iOS** | <1ms (CGEventTap) | ~15ms (AXUIElement) | No | **<20ms** |
| **AutoPilot Android** | <5ms (getevent) | ~6ms (AgentBridge) | No | **<15ms** |
| **AutoPilot Android (legacy)** | <5ms (getevent) | ~2000ms (uiautomator) | No | **~2s** |
| Maestro Studio | ~16ms (screenshot) | ~100ms | Si | **~2100ms** |
| Appium Inspector | ~5ms (session log) | ~200ms (XPath) | Si | **~400ms** |
| WDA | ~10ms | ~100ms (NSPredicate) | Si | **~250ms** |

### Selector semantico (medido)

| Herramienta | Selector default | Estabilidad | Ejemplo |
|-------------|-----------------|-------------|---------|
| **AutoPilot** | id > label > [N] > tapAt | Alta | `tap "Confirmar"` |
| Maestro | text > id > index | Media | `tapOn: "Confirmar"` |
| Appium Inspector | XPath (default) | Baja | `/XCUIElementTypeButton[2]` |
| WDA | NSPredicate | Media | `predicate: label == "Confirmar"` |

### Replicabilidad E2E (medida — Explorea app, 22 pasos)

| Herramienta | Script raw | Script editado | Ediciones | Scroll |
|-------------|-----------|----------------|-----------|--------|
| **AutoPilot iOS** | 0% (0/5) | **100%** (50/50) | 1 (swipe) | No detecta |
| **AutoPilot Android** | 0% (0/5) | **100%** (3/3) | 2 (swipe+wait) | Detecta parcial |
| Maestro | ~70-75%* | ~85%* | waitFor timings | Detecta (visual) |
| Appium (XPath) | ~40-55%* | ~65%* | XPath + waits | Detecta (session) |

*Estimaciones del RFC basadas en issues documentados. AutoPilot son mediciones reales.

### Que cada herramienta hace mejor

| Aspecto | Mejor herramienta | Por que |
|---------|-------------------|---------|
| Scroll recording | **Maestro** | Comparacion visual de screenshots |
| Velocidad de captura | **AutoPilot** | CGEventTap/getevent pasivo, sin bloqueo |
| Selector semantico | **AutoPilot** | Cascada id > label > [N] con role verification |
| waitFor inteligente | **AutoPilot** | State-based (gap + transicion), no timer fijo |
| CI/CD sin setup | **AutoPilot** | Binario standalone, sin servidor |
| Ecosystem/comunidad | **Maestro** | YAML, docs, plugins, market share |
| Multi-lenguaje | **Appium** | Java, Python, JS, Ruby, C# |
| iOS + Android parity | **Empate** | Todos soportan ambos |

### Que falta para ganarle a Maestro en recording

1. **Scroll detection** — Maestro compara screenshots para detectar scroll. AutoPilot no puede detectar scroll del trackpad en iOS.
2. **scrollUntilVisible** — verificar que el elemento esta en el viewport antes de declarar "encontrado".
3. **Android keyboard recording** — teclado virtual son touch events, no key events.
4. **Android system dialog detection** — solo implementado en iOS.
5. **waitUntilGone** — Maestro no lo tiene pero seria diferenciador.
6. **assertOCR / assertScreen** — verificacion visual post-accion.

---

## Referencias

- [Can You Mimic Me? Exploring Android Record & Replay Tools — ArXiv 2504.20237](https://arxiv.org/html/2504.20237)
- [Appium Inspector Recorder Docs](https://appium.github.io/appium-inspector/latest/session-inspector/recorder/)
- [WDA Performance Best Practices — Facebook Archive](https://github.com/facebookarchive/WebDriverAgent/wiki/How-To-Achieve-The-Best-Lookup-Performance)
- [Maestro Selectors Reference](https://docs.maestro.dev/api-reference/selectors)
- [Maestro waitForAnimationToEnd](https://docs.maestro.dev/api-reference/commands/waitforanimationtoend)
- [iOS XPath vs NSPredicate — Appium Pro](https://appiumpro.com/editions/8-how-to-find-elements-in-ios-not-by-xpath)
- [Self-Healing Tests — Maestro Insights](https://maestro.dev/insights/self-healing-tests-fixing-flaky-ui-automation)
