# Capitulo 6 — Alternativas

## Por que listamos a la competencia

En 2022, Brandon Williams y Stephen Celis de [Point-Free](https://www.pointfree.co) hicieron algo poco comun: publicaron una pagina en su sitio listando cada competidor de su libreria de Composable Architecture, explicando que hacia bien cada uno y en que se diferenciaban. No fue un truco de marketing. Fue un acto de respeto — hacia los usuarios que merecen tomar decisiones informadas, y hacia los equipos que construyeron esas herramientas.

Este capitulo sigue esa filosofia.

AutoPilot existe en un ecosistema con herramientas maduras, bien financiadas, con comunidades activas. Varias de ellas resuelven problemas que AutoPilot aun no toca. Otras llevan anos de ventaja en integraciones, documentacion y soporte. Si una de ellas resuelve tu problema, usala.

Lo que ofrecemos aqui es un analisis tecnico honesto: como funciona cada herramienta por dentro, que decisiones arquitectonicas tomaron, donde brillan y donde tienen fricciones. Con esa informacion, puedes decidir que camino tomar.

---

## El landscape

La automatizacion iOS se puede dividir en cuatro capas, segun donde vive la herramienta:

```
┌─────────────────────────────────────────────────────────┐
│  Capa 4 — Orquestadores de alto nivel                   │
│  Maestro (YAML), Detox (JS), frameworks de QA           │
├─────────────────────────────────────────────────────────┤
│  Capa 3 — Protocolos intermedios                        │
│  Appium (WebDriver W3C), idb (gRPC)                    │
├─────────────────────────────────────────────────────────┤
│  Capa 2 — Frameworks de acceso a UI                     │
│  XCUITest, EarlGrey, WebDriverAgent                     │
├─────────────────────────────────────────────────────────┤
│  Capa 1 — APIs del sistema operativo                    │
│  AXUIElement (macOS, publica), Accessibility (privada)  │
│  DYLD_INSERT_LIBRARIES, CoreSimulator (privada)         │
└─────────────────────────────────────────────────────────┘
```

La mayoria de las herramientas opera en las capas 3 y 4, construyendo sobre XCUITest como base. AutoPilot y AXe son las unicas que operan directamente en la capa 1.

Esta decision tiene consecuencias profundas. Operar en capas altas da acceso a ecosistemas maduros, documentacion abundante y soporte comunitario. Operar en la capa 1 da control total, menos dependencias, pero tambien mas responsabilidad sobre cada detalle.

---

## XCUITest

**Creador:** Apple
**Lenguaje:** Swift / Objective-C
**Desde:** 2015 (Xcode 7)

### Como funciona

XCUITest es el framework de Apple para UI testing. Requiere un test target dentro de un proyecto de Xcode, que se compila junto con la app y se ejecuta a traves de un test runner. Internamente, XCUITest usa APIs privadas de accesibilidad de iOS — no de macOS — para interactuar con la UI.

El flujo es: Xcode compila el test bundle, lo instala en el simulador (o dispositivo), lanza un proceso `XCTRunner` que coordina la ejecucion, y cada `XCUIElement.tap()` se traduce a un evento de toque sintetico dentro de iOS.

```swift
// XCUITest clasico
func testLogin() {
    let app = XCUIApplication()
    app.launch()
    app.textFields["Email"].tap()
    app.textFields["Email"].typeText("user@test.com")
    app.buttons["Login"].tap()
    XCTAssert(app.staticTexts["Welcome"].waitForExistence(timeout: 5))
}
```

### Que hace bien

- Es el framework oficial de Apple. Cualquier comportamiento de accesibilidad que Apple soporte, XCUITest lo ve.
- Integracion nativa con Xcode: breakpoints, grabacion de tests, reportes.
- No necesita dependencias externas si ya tienes Xcode.
- Es la base sobre la que funcionan Appium, Maestro y WebDriverAgent.

### Limitaciones

- Requiere un test target compilado con el proyecto. No puedes automatizar una app de la que solo tienes el `.app` bundle.
- Cada ejecucion implica un ciclo de compilacion. En CI, esto agrega minutos.
- No hay forma nativa de correr scripts desde la terminal sin `xcodebuild test`.
- No tiene camera mock, no tiene inyeccion de sensores, no tiene control de red.
- El matching de elementos tiene quirks: botones en SwiftUI `NavigationBar` reportan `AXChildren = [0]`, placeholders viven en atributos inconsistentes entre versiones.

### Diferencia clave con AutoPilot

XCUITest opera *dentro* de iOS. AutoPilot opera *desde fuera*, desde macOS. XCUITest necesita compilar un test target; AutoPilot necesita solo el PID del Simulador. XCUITest es un framework de testing; AutoPilot es una herramienta de automatizacion — no asume que estas escribiendo tests.

---

## Appium

**Repositorio:** [appium/appium](https://github.com/appium/appium) — 21.4K stars
**Lenguaje:** Node.js (servidor), clientes en Python/Java/Ruby/C#
**Protocolo:** WebDriver W3C
**Desde:** 2013

### Como funciona

Appium es un servidor HTTP que implementa el protocolo WebDriver W3C — el mismo estandar que usan Selenium y los navegadores. Para iOS, Appium usa un driver llamado `appium-xcuitest-driver` que internamente despliega **WebDriverAgent** (WDA) en el simulador o dispositivo. WDA es un proceso que corre dentro del entorno iOS, escucha en un puerto HTTP, recibe comandos JSON, y los traduce a llamadas de XCUITest.

```
Cliente (Python/Java)
    │ HTTP POST /session/.../element
    ▼
Appium Server (Node.js, puerto 4723)
    │ HTTP → WebDriverAgent
    ▼
WDA (dentro del Simulador, puerto 8100)
    │ XCUITest APIs
    ▼
App iOS
```

El setup tipico involucra: Node.js + npm, `appium` CLI global, el driver de iOS (`appium driver install xcuitest`), opcionalmente Java para Android, y un cliente en el lenguaje de tu eleccion.

### Que hace bien

- Es el estandar de facto en enterprise. Si llegas a una empresa grande, probablemente ya tienen Appium.
- Soporta iOS, Android, Windows, Mac, y custom drivers. Un equipo puede unificar todo bajo un protocolo.
- La comunidad es enorme: miles de plugins, integraciones con Sauce Labs, BrowserStack, LambdaTest.
- Los clientes multi-lenguaje permiten que equipos de QA usen Python o Java, no Swift.
- El modelo de sesiones permite correr multiples tests en paralelo con diferentes capabilities.

### Limitaciones

- El stack completo requiere 3-5 procesos corriendo simultaneamente: tu test, el servidor Appium, WDA, el simulador, y opcionalmente un proxy.
- El overhead de HTTP entre cada capa agrega latencia. Un tap que toma 89ms nativamente puede tomar 200-500ms a traves de Appium.
- WDA necesita re-compilarse cuando cambias de Xcode. Es una fuente constante de errores en CI: `Unable to launch WebDriverAgent`, `Session creation failed`.
- No tiene camera mock nativo. La solucion es usar servicios cloud (BrowserStack tiene `cameraMock` capability) o mockear a nivel de app.
- El debugging cuando algo falla es complejo: ¿fallo el cliente? ¿el servidor? ¿WDA? ¿XCUITest? La cadena es larga.

### Diferencia clave con AutoPilot

Appium es una capa de abstraccion sobre XCUITest. AutoPilot elimina esa cadena por completo: no hay servidor, no hay protocolo HTTP, no hay WDA. El CLI habla directamente con las APIs de accesibilidad de macOS. Appium es la mejor opcion si necesitas multi-plataforma con un equipo de QA existente. AutoPilot esta disenado para ingenieros iOS que quieren control directo.

---

## Maestro

**Repositorio:** [mobile-dev-inc/maestro](https://github.com/mobile-dev-inc/maestro) — 13.4K stars
**Lenguaje:** Kotlin / JVM
**Desde:** 2022

### Como funciona

Maestro es una herramienta CLI que ejecuta flujos definidos en YAML. Su propuesta es simple: defines pasos como `tapOn`, `assertVisible`, `inputText`, y Maestro se encarga del resto. Se instala con un `curl | bash`.

Por debajo, Maestro lanza un **XCUITest "zombie"** — un test target que nunca termina — que levanta un servidor HTTP interno. El flujo es:

1. Maestro CLI (Kotlin/JVM) lee el YAML.
2. Envia comandos HTTP al servidor dentro del XCUITest runner.
3. El runner ejecuta acciones via XCUITest APIs.
4. El matching de elementos (por texto, id, index) lo hace Maestro en Kotlin, no XCUITest. El runner solo envia el arbol de accesibilidad completo.

```yaml
# flow.yaml
appId: com.example.app
---
- launchApp
- tapOn: "Login"
- inputText: "user@test.com"
- tapOn: "Submit"
- assertVisible: "Welcome"
```

Requiere Java/JVM instalado. El binario de instalacion descarga una JVM embebida si no la encuentra.

### Que hace bien

- La experiencia de primer uso es excelente. `curl | bash`, escribe un YAML, corre `maestro test flow.yaml`. Dos minutos y funciona.
- Los GIF demos en el README son convincentes — ves la automatizacion corriendo en tiempo real.
- Maestro Cloud ofrece CI/CD sin configurar infraestructura.
- El YAML es accesible para QA engineers que no programan en Swift o Kotlin.
- El matching por texto es inteligente: busca en labels, placeholders, values, hints.

### Limitaciones

- El YAML, cuando los flujos crecen, se vuelve limitante. No hay variables con logica, no hay funciones, no hay composicion real. Hay workarounds (`runFlow`, variables de entorno), pero no es un lenguaje.
- Requiere JVM. En CI, esto son ~200MB adicionales. En maquinas de desarrolladores, es otra runtime que mantener.
- Depende de XCUITest por debajo. Los mismos quirks del arbol de accesibilidad aplican.
- No tiene camera mock. Si tu app abre `AVCaptureSession`, Maestro no puede interceptar eso.
- El servidor HTTP interno significa que hay un proceso extra corriendo en el simulador. En simuladores con poca memoria, esto puede causar inestabilidad.

### Diferencia clave con AutoPilot

Maestro optimiza la experiencia del usuario sobre YAML. AutoPilot optimiza la transparencia — puedes ver exactamente que API se llama en cada paso. Maestro necesita JVM + XCUITest; AutoPilot es un binario Swift de ~2MB sin dependencias. AutoPilot tiene camera mock via DYLD_INSERT_LIBRARIES; Maestro no puede interceptar la camara. Si tu equipo es QA-first y no necesita camara, Maestro es una opcion solida.

---

## Detox

**Repositorio:** [wix/Detox](https://github.com/wix/Detox) — 11.9K stars
**Lenguaje:** JavaScript / Objective-C
**Desde:** 2017

### Como funciona

Detox es un framework de testing "gray box" creado por Wix, disenado especificamente para React Native. "Gray box" significa que Detox tiene acceso tanto a la interfaz (como un usuario) como a los internos de la app (como un debugger).

En iOS, Detox usa **EarlGrey 2.0** como motor de interaccion con la UI. El componente clave es la sincronizacion: Detox espera a que el JavaScript event loop de React Native, las animaciones nativas, las peticiones de red y las transiciones de navegacion terminen *antes* de ejecutar el siguiente paso. Esto elimina la mayoria de los `waitFor` manuales.

```javascript
// Detox test
describe('Login', () => {
  it('should login successfully', async () => {
    await element(by.id('email')).typeText('user@test.com');
    await element(by.id('password')).typeText('password');
    await element(by.text('Login')).tap();
    await expect(element(by.text('Welcome'))).toBeVisible();
  });
});
```

### Que hace bien

- La sincronizacion automatica es su killer feature. En React Native, los flaky tests suelen venir de timing — Detox resuelve esto a nivel de framework.
- La API es ergonomica y familiar para desarrolladores JavaScript.
- Wix lo usa internamente en produccion con apps de millones de usuarios. No es un proyecto de fin de semana.
- El modelo gray box permite verificar estado interno de la app, no solo lo visible en pantalla.

### Limitaciones

- Solo funciona con React Native. Si tu app es Swift nativo o SwiftUI, Detox no aplica.
- Requiere Node.js, npm, y un build especial de la app con el server de Detox embebido.
- EarlGrey 2.0, su motor interno, depende de XCUITest. Heredas sus limitaciones.
- Camera mock es posible solo a traves de modulos React Native que wrappean la camara — no es una solucion generica.
- La configuracion inicial (`detox build`, `detox test`, archivos de configuracion por plataforma) tiene curva de aprendizaje.

### Diferencia clave con AutoPilot

Detox resuelve un problema especifico (testing de React Native) muy bien. AutoPilot resuelve un problema diferente (automatizacion de cualquier app iOS desde la terminal). No compiten directamente. Si tu stack es React Native, Detox es probablemente la mejor opcion para testing de UI.

---

## AXe

**Repositorio:** [AXe](https://github.com/nicklama/axe) — 1.7K stars
**Lenguaje:** Swift
**Desde:** 2025

### Como funciona

AXe es el competidor mas directo de AutoPilot. Comparte la misma filosofia: binario unico, Swift puro, CLI, sin XCUITest, sin servidor. Se instala via Homebrew (`brew install axe`).

La diferencia tecnica fundamental esta en *que* APIs usa. AXe utiliza **APIs privadas de accesibilidad de Apple** — funciones que no estan en la documentacion publica, que Apple no garantiza que se mantengan entre versiones. Estas APIs dan acceso mas directo a elementos dentro del simulador, pero con un riesgo: pueden romperse en cualquier actualizacion de macOS o Xcode sin previo aviso.

AutoPilot usa **APIs publicas de macOS** (`AXUIElement`, `AXUIElementCopyAttributeValue`, `AXUIElementPerformAction`) — las mismas que usan lectores de pantalla y herramientas de accesibilidad certificadas por Apple. Son estables, documentadas, y parte del contrato publico del sistema operativo.

### Que hace bien

- La experiencia de instalacion es excelente: `brew install axe` y listo.
- Es rapido. Un binario Swift nativo sin overhead de runtime.
- El crecimiento rapido (1.7K stars en meses) valida que hay un mercado real para herramientas de automatizacion iOS ligeras.
- Demuestra que el enfoque de "binario unico sin XCUITest" es viable.

### Limitaciones

- Las APIs privadas son fragiles. Cada major release de macOS o Xcode puede romper funcionalidad sin advertencia. El equipo de AXe tiene que hacer ingenieria inversa despues de cada actualizacion.
- No tiene camera mock.
- Al depender de APIs privadas, no puede distribuirse en contextos donde Apple audita el uso de APIs (como Mac App Store o entornos enterprise con politicas de compliance).
- La documentacion esta principalmente en ingles.

### Diferencia clave con AutoPilot

AXe y AutoPilot ven el mismo problema desde angulos opuestos. AXe apuesta por APIs privadas: mas poder inmediato, mas riesgo a largo plazo. AutoPilot apuesta por APIs publicas: mas trabajo de integracion, pero estabilidad garantizada por Apple. Ademas, AutoPilot ofrece camera mock via inyeccion de dylib — algo que AXe no tiene y que ningun otro competidor implementa.

La existencia de AXe es, para nosotros, una validacion. Dos equipos independientes llegaron a la misma conclusion: la automatizacion iOS debe ser un binario nativo que hable AX, no un wrapper sobre XCUITest.

---

## idb

**Repositorio:** [facebook/idb](https://github.com/facebook/idb) — 5K stars
**Lenguaje:** Objective-C++ (servidor), Python (cliente)
**Creador:** Meta (Facebook)
**Desde:** 2019

### Como funciona

idb (iOS Development Bridge, un guino a `adb` de Android) es la herramienta interna de Meta para interactuar con simuladores y dispositivos iOS. Tiene dos componentes: un **companion** escrito en Objective-C++ que corre en la Mac y linkea directamente contra frameworks privados de Apple (`CoreSimulator.framework`, `SimulatorKit.framework`), y un **cliente** en Python que se comunica via gRPC.

El companion puede: instalar apps, lanzarlas, tomar screenshots, ejecutar `xctest`, interactuar con el pasteboard, obtener logs, y — crucialmente — hacer fetching del arbol de accesibilidad.

```bash
# idb en accion
idb launch com.example.app
idb ui describe-all        # arbol de accesibilidad
idb ui tap 150 300         # tap por coordenadas
idb ui type "hello"        # typing
```

### Que hace bien

- Es la herramienta que Meta usa internamente para miles de tests diarios. Esta probada a escala.
- El companion tiene acceso profundo al simulador: puede manipular permisos, pasteboard, localizacion.
- El accessibility fetching es rapido y completo.
- El modelo companion + cliente permite correr el companion en una Mac remota y controlarlo desde cualquier maquina.

### Limitaciones

- Requiere Python para el cliente. En entornos iOS-only, esto es una dependencia extra.
- Linkea contra frameworks privados de Apple. Al igual que AXe, cada actualizacion de Xcode puede romper la compilacion.
- El tap es por coordenadas, no por label. Para automatizacion por elementos, necesitas combinar `describe-all` con parsing propio.
- No tiene camera mock.
- El proyecto ha tenido periodos de baja actividad — el riesgo de cualquier herramienta interna open-sourced.

### Diferencia clave con AutoPilot

idb es una navaja suiza para el simulador: puede hacer muchas cosas, pero no esta disenada como herramienta de automatizacion de UI. Su tap es por coordenadas; AutoPilot tapa por label. Su cliente es Python; AutoPilot es un binario autocontenido. Ambos evitan XCUITest, pero por caminos diferentes: idb linkea frameworks privados, AutoPilot usa APIs publicas de macOS.

---

## EarlGrey

**Repositorio:** [google/EarlGrey](https://github.com/google/EarlGrey) — 5.7K stars
**Lenguaje:** Objective-C
**Creador:** Google
**Desde:** 2016

### Como funciona

EarlGrey es un framework de testing "gray box" de Google para iOS nativo. Originalmente (1.0) funcionaba como un framework que se embedia directamente en la app, con acceso al mismo proceso — podia esperar animaciones, network calls, y dispatch queues.

EarlGrey 2.0 cambio el modelo: ahora se integra *con* XCUITest en lugar de reemplazarlo. El test corre en el proceso de XCUITest, pero un componente embebido en la app (via un framework adicional) provee la sincronizacion.

```objc
// EarlGrey 2.0
- (void)testLogin {
  [[EarlGrey selectElementWithMatcher:grey_accessibilityID(@"email")]
      performAction:grey_typeText(@"user@test.com")];
  [[EarlGrey selectElementWithMatcher:grey_text(@"Login")]
      performAction:grey_tap()];
  [[EarlGrey selectElementWithMatcher:grey_text(@"Welcome")]
      assertWithMatcher:grey_sufficientlyVisible()];
}
```

### Que hace bien

- La sincronizacion de EarlGrey 1.0 era revolucionaria para su epoca. Eliminaba waits arbitrarios.
- La API de matchers es expresiva y composable.
- Google lo usa(ba) internamente para apps como YouTube, Google Maps, Gmail.

### Limitaciones

- EarlGrey 1.0 esta deprecado.
- EarlGrey 2.0 depende completamente de XCUITest. Perdio la ventaja principal del modelo gray box original.
- El proyecto tiene actividad minima. Los issues se acumulan, los PRs tardan meses en revisarse.
- La configuracion de EarlGrey 2.0 es compleja: necesitas un test target, el framework de EarlGrey en la app, y el componente en el test target.
- No tiene camera mock.
- La comunidad ha migrado mayoritariamente a XCUITest nativo o a Maestro.

### Diferencia clave con AutoPilot

EarlGrey representa un enfoque que tuvo su momento pero esta en declive. Su contribucion historica — sincronizacion automatica — fue adoptada por Detox y, parcialmente, por XCUITest. AutoPilot no compite con EarlGrey directamente; mencionamos la herramienta para dar contexto historico y porque Detox la usa internamente.

---

## Tabla comparativa

| | AutoPilot | Maestro | Appium | XCUITest | Detox | AXe | idb |
|---|---|---|---|---|---|---|---|
| **Lenguaje** | Swift | Kotlin | Node.js | Swift/ObjC | JS/ObjC | Swift | ObjC++/Python |
| **Dependencias runtime** | Ninguna | JVM | Node + drivers | Xcode | Node | Ninguna | Python |
| **Instalacion** | Binario | curl + JVM | npm + plugins | Ya incluido | npm | brew | pip + build |
| **Usa XCUITest** | No | Si (zombie) | Si (WDA) | Es XCUITest | Si (EarlGrey) | No | Parcial |
| **APIs de acceso** | AX publicas | XCUITest HTTP | WebDriver W3C | Privadas iOS | EarlGrey 2.0 | AX privadas | Frameworks privados |
| **Camera mock** | Si (dylib) | No | No* | No | No** | No | No |
| **Tap por label** | Si | Si | Si | Si | Si | Si | No (coordenadas) |
| **Multi-plataforma** | Solo iOS | iOS + Android | iOS + Android + Web | Solo iOS | Solo RN | Solo iOS | Solo iOS |
| **Formato de scripts** | .auto | YAML | Codigo (multi-lang) | Swift/ObjC | JavaScript | CLI args | CLI args |
| **Stars** | — | 13.4K | 21.4K | — | 11.9K | 1.7K | 5K |

\* Appium soporta camera mock a traves de servicios cloud (BrowserStack, Sauce Labs), no nativamente.
\** Detox puede mockear camara a traves de modulos React Native, no a nivel de sistema.

---

## Por que elegimos otro camino

No elegimos construir AutoPilot porque las alternativas sean malas. Las elegimos porque resuelven un problema diferente al que nos interesa.

**El stack convencional** (Appium, Maestro, XCUITest) asume que quieres escribir *tests*. Asume un runner, un framework de assertions, un reporte de resultados. La herramienta vive en el mundo de QA.

**AutoPilot asume que quieres *controlar* el simulador.** Quieres hacer tap, leer la pantalla, inyectar una imagen como camara, tomar un screenshot — desde la terminal, sin compilar nada, sin levantar servidores, sin instalar runtimes. Que despues uses eso para testing, para demos, para CI, o para explorar una app que no compilaste tu, es tu decision.

Las decisiones que se derivan de esa premisa son:

1. **Swift puro, binario unico.** Si la herramienta es para ingenieros iOS, debe hablar su idioma y no pedirles instalar Node, Java o Python.

2. **APIs publicas de macOS.** Las APIs privadas dan mas poder hoy, pero las publicas dan estabilidad manana. Preferimos construir sobre un contrato que Apple mantiene para millones de usuarios con discapacidad.

3. **Camera mock via DYLD_INSERT_LIBRARIES.** Nadie mas hace esto. No porque sea imposible, sino porque requiere un conocimiento profundo del ObjC runtime, ARM64 PAC, y el pipeline de AVFoundation. Es nuestra contribucion unica al espacio.

4. **Scripts .auto en lugar de YAML o codigo.** Un formato simple, legible, que se puede generar, parsear y depurar sin un IDE.

### Cuando no usar AutoPilot

Seamos directos:

- **Si necesitas iOS + Android con un solo framework**, usa Maestro o Appium. AutoPilot es solo iOS (por ahora).
- **Si tu equipo es de QA y no programa en Swift**, usa Maestro (YAML) o Appium (Python/Java).
- **Si necesitas el ecosistema enterprise** (Sauce Labs, BrowserStack, reportes HTML, integraciones con Jira), usa Appium.
- **Si tu app es React Native**, Detox resuelve el problema de sincronizacion mejor que cualquier herramienta generica.
- **Si solo necesitas tests basicos y ya estas en Xcode**, XCUITest funciona sin instalar nada adicional.

### Cuando AutoPilot tiene sentido

- Cuando quieres automatizar sin compilar un test target.
- Cuando necesitas camera mock en el simulador y no quieres pagar $400/mes por un servicio cloud.
- Cuando quieres un binario de 2MB que funciona con `./auto tap "Login"` y nada mas.
- Cuando quieres entender *exactamente* que hace tu herramienta de automatizacion, linea por linea.
- Cuando valoras la independencia de runtimes externos.

El ecosistema de automatizacion iOS necesita diversidad de enfoques. XCUITest es la base solida que Apple mantiene. Appium es el estandar enterprise probado a escala. Maestro es la experiencia de usuario mas pulida. AXe valida que el enfoque nativo sin XCUITest es viable. AutoPilot aporta APIs publicas, camera mock, y transparencia total.

Cada herramienta eligio sus trade-offs. Nosotros elegimos los nuestros.

---

*Anterior: [Capitulo 5 — El editor](05-el-editor.md)*
*Siguiente: [Capitulo 7 — Decisiones](07-decisiones.md)*
