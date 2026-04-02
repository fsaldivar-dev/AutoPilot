# Capitulo 7 — Decisiones

Cada proyecto tecnico acumula decisiones que rara vez se documentan. Se toman en una conversacion, en un commit a las 11 de la noche, o despues de tres intentos fallidos. Meses despues, alguien pregunta "¿por que se hizo asi?" y nadie recuerda el contexto.

Este capitulo documenta las decisiones arquitectonicas de AutoPilot en formato ADR (Architecture Decision Record). Cada una incluye el contexto real en el que se tomo, las opciones que evaluamos, lo que elegimos, y las consecuencias — buenas y malas. No hay decisiones perfectas; hay decisiones informadas con tradeoffs explicitos.

---

## Indice de ADRs

| ADR | Titulo | Estado |
|-----|--------|--------|
| 1 | Swift puro sin dependencias | Aceptada |
| 2 | AXUIElement publicas, no APIs privadas | Aceptada |
| 3 | Sin XCUITest | Aceptada |
| 4 | Scripts .auto, no YAML ni JavaScript | Aceptada |
| 5 | Tauri, no Electron | Aceptada |
| 6 | DYLD_INSERT_LIBRARIES vs force_load | Aceptada |
| 7 | ObjC swizzle con #undef AV_INIT_UNAVAILABLE | Aceptada |

---

### ADR 1: Swift puro sin dependencias

**Contexto:** Necesitabamos un CLI para macOS que pudiera leer el arbol de accesibilidad del Simulador, enviar eventos de toque, y controlar `simctl`. La pregunta inicial era simple: ¿en que lenguaje lo escribimos?

**Opciones:**

1. **Python** — Rapido de prototipar. Tiene `pyobjc` para acceder a APIs de macOS. Comunidad enorme, miles de librerías CLI. Pero requiere runtime instalado, la interaccion con AXUIElement via `pyobjc` es indirecta y fragil, y distribuir un binario standalone en Python es un dolor (PyInstaller, cx_Freeze, etc.).

2. **Go** — Binario estatico, cross-platform, excelente tooling CLI (cobra, viper). Pero no tiene acceso nativo a frameworks de macOS. Llamar a AXUIElement desde Go requiere CGo + bindings manuales en C. Cada API de macOS que necesitas es otro binding que mantener.

3. **Rust** — Performance, safety, binario estatico. Tiene crates para macOS (`accessibility`, `core-foundation`). Pero los bindings a AXUIElement en Rust son wrappers de terceros con coverage parcial. Y el equipo no tenia experiencia profunda en Rust.

4. **Swift** — Nativo de macOS. AXUIElement, CGEvent, CoreFoundation, NSWorkspace, IOKit — todas son APIs de macOS en C/ObjC que Swift llama directamente sin FFI, sin bindings, sin wrappers. SPM como build system. El mismo lenguaje que las apps que estamos automatizando.

**Decision:** Swift. No por preferencia estetica sino por acceso directo: las APIs que necesitamos son de macOS y Swift las llama sin intermediarios.

```swift
// Esto es todo lo que necesitas para leer el arbol de accesibilidad.
// Sin import de terceros, sin bindings, sin FFI.
let app = AXUIElementCreateApplication(pid)
var value: AnyObject?
AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value)
```

**Consecuencias:**

Lo que ganamos:
- Sin dependencias externas. Cero. `Package.swift` solo tiene targets del proyecto.
- Binario de 311KB. Se copia con `cp`, se distribuye con GitHub Releases.
- Acceso directo a todo macOS: AXUIElement para leer UI, CGEvent para teclado, `Process` + `xcrun simctl` para control del simulador, NSWorkspace para activar apps.
- El CLI compila en 3 segundos en una MacBook Air M1.

Lo que perdemos:
- Solo macOS. Si algun dia queremos Linux o Windows, no sirve.
- La comunidad de herramientas CLI en Swift es pequena comparada con Go o Python. No hay equivalente a `cobra` o `click`.
- SPM tiene sus limitaciones (no soporta plugins pre-build de forma ergonomica, los tests de integracion son incomodos).
- Los ingenieros que conozcan Go o Python no pueden contribuir sin aprender Swift.

---

### ADR 2: AXUIElement publicas, no APIs privadas

**Contexto:** Para leer la UI del Simulador iOS necesitamos Accessibility APIs de macOS. Hay tres niveles de acceso: las APIs publicas documentadas (`AXUIElement*`), las APIs privadas que Apple usa internamente (como las que usa AXe), y XCUITest que expone su propio arbol.

**Opciones:**

1. **APIs publicas de macOS (AXUIElement)** — Documentadas en `ApplicationServices/HIServices`. Estables entre versiones de macOS. Requieren permiso de Accessibility en TCC. Funcionalidad limitada a lo que Apple expone publicamente.

2. **APIs privadas de Apple** — Herramientas como AXe usan frameworks privados (`AccessibilityUIService`, `AXRuntime`) que exponen mas funcionalidad: snapshots completos, jerarquias mas profundas, atributos internos. Pero no estan documentadas, cambian sin aviso entre versiones, y Apple puede bloquearlas en cualquier momento.

3. **XCUITest** — Tiene su propio mecanismo para leer el arbol de accesibilidad via `XCUIApplication.debugDescription`. Funciona bien dentro de su ecosistema. Pero requiere compilar un test target, lo que contradice nuestra premisa de cero compilacion.

**Decision:** APIs publicas. Usamos exclusivamente `AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`, `AXUIElementPerformAction` y funciones relacionadas del framework publico de macOS.

**Consecuencias:**

Lo que ganamos:
- Estabilidad entre versiones de macOS. El mismo codigo funciona en macOS 13, 14 y 15 sin cambios.
- Documentacion oficial de Apple. Cuando algo no funciona, hay referencia para entender por que.
- No rompemos con actualizaciones de Xcode. Las APIs privadas cambian con cada beta; las publicas no.
- Legitimidad: no estamos haciendo nada que Apple no permita. Es la misma API que usan VoiceOver, Hammerspoon, y decenas de herramientas de accesibilidad.

Lo que perdemos:
- AXe puede hacer cosas que nosotros no. Por ejemplo, obtener snapshots del arbol entero en una sola llamada, sin iterar recursivamente.
- Algunos elementos no se exponen. Los botones de SwiftUI NavigationBar reportan `AXChildren = [0]` — existen visualmente pero la API publica no los ve. Tuvimos que implementar fallbacks con CGEvent (click por coordenadas).
- Requiere que el usuario otorgue permiso de Accessibility en System Settings. En CI, esto se configura con `tccutil` o con perfiles MDM.

---

### ADR 3: Sin XCUITest

**Contexto:** XCUITest es el camino "oficial" de Apple para automatizar UI en iOS. Maestro lo usa internamente (lanza un XCUITest "zombie" persistente). Appium lo usa via WebDriverAgent. Es la base de practicamente todas las herramientas del ecosistema.

**Opciones:**

1. **Usar XCUITest como capa interna** — Como hace Maestro: lanzar un test runner persistente que expone un servidor HTTP. Nuestro CLI hablaria con ese servidor. Ventaja: acceso a las APIs de matching de XCUITest (`XCUIApplication.buttons["Login"]`). Desventaja: necesitas compilar un test target, necesitas un proyecto Xcode, el runner a veces crashea y hay que reiniciarlo.

2. **No usar XCUITest** — Reemplazarlo completamente con AXUIElement + CGEvent + simctl. Ventaja: cero compilacion, funciona con cualquier app instalada. Desventaja: tienes que implementar tu propio sistema de matching de elementos.

**Decision:** No usarlo. Si lo usaramos, seriamos otro wrapper de XCUITest — como Maestro, como Appium. La propuesta de AutoPilot es que hay otro camino.

**Consecuencias:**

Lo que ganamos:
- No necesitas un proyecto Xcode para automatizar una app. Puedes automatizar una app descargada del App Store (en Simulador).
- No compilas un test target. `auto tap "Login"` funciona en 89ms, no en 15 segundos de build + launch.
- No hay runner que crashee, no hay sesiones zombies, no hay servidor HTTP intermedio.
- Funciona con apps de terceros: puedes automatizar Safari, Settings, cualquier app del sistema.

Lo que perdemos:
- No tenemos las APIs de matching de XCUITest. Tuvimos que implementar nuestro propio `ElementIndex` que recorre el arbol AX recursivamente y matchea por label, tipo, indice y otros atributos.
- XCUITest tiene `waitForExistence(timeout:)` integrado. Nosotros implementamos nuestro propio `waitFor` con polling.
- No podemos acceder a ciertas APIs internas de la app (estado de vistas, propiedades custom). Solo vemos lo que AXUIElement expone.
- La documentacion y los tutoriales del ecosistema iOS asumen XCUITest. Estamos fuera de ese camino.

---

### ADR 4: Scripts .auto, no YAML ni JavaScript

**Contexto:** Los usuarios necesitan escribir secuencias de acciones automatizadas. Necesitabamos un formato para definir esos scripts. La pregunta era: ¿usamos un formato existente o creamos uno propio?

**Opciones:**

1. **YAML** — Es lo que usa Maestro (`appId: com.example.app`, `- tapOn: "Login"`). Estructurado, legible, soporte en todos los editores. Pero YAML tiene sus trampas (indentacion significativa, tipos implicitos — `yes` es boolean, `3.10` es float), y requiere un parser que mapee YAML a acciones.

2. **JavaScript** — Es lo que usa Detox (`await element(by.text('Login')).tap()`). Maximo poder: condicionales, variables, funciones. Pero requiere runtime (Node/JavaScriptCore), y el poder del lenguaje se vuelve complejidad — cada script es un programa que puede fallar de formas inesperadas.

3. **JSON** — Estructurado, sin ambiguedades, soporte universal. Pero verboso e incomodo de escribir a mano. Nadie quiere poner llaves y comillas para decir "tap Login".

4. **Formato propio (.auto)** — Una linea = un comando. La misma sintaxis que el CLI. Sin parser complejo: split por espacios, el primer token es el comando, el resto son argumentos.

**Decision:** Formato propio. Un script `.auto` es una lista de comandos, uno por linea, con la misma sintaxis que usarias en la terminal.

```bash
# Esto es un script .auto completo
ping
tap Login
type "usuario@email.com"
tap Password
type "miPassword123"
tap "Sign In"
waitFor "Welcome" 10
screenshot resultado.png
```

**Consecuencias:**

Lo que ganamos:
- Cero curva de aprendizaje. Si sabes usar el CLI, sabes escribir un script.
- Cero parsing overhead. No necesitamos librerias de YAML, JSON, ni un interprete de JavaScript.
- Un script `.auto` es legible por cualquier persona, incluyendo QA no-tecnico y product managers.
- El mismo comando funciona en terminal (`auto tap Login`) y en script (`tap Login`). No hay dos mundos.

Lo que perdemos:
- No hay condicionales. No puedes hacer `if elementExists("Error") then retry`. Por ahora.
- No hay variables. No puedes hacer `email = "test@mail.com"` y reutilizarlo.
- No hay loops. No puedes iterar sobre una lista de datos.
- No es un estandar. Nadie mas usa `.auto`, no hay tooling del ecosistema (linters, formatters, integraciones).
- Eventualmente necesitaremos control flow, y tendremos que decidir si evolucionamos `.auto` o adoptamos un lenguaje existente.

---

### ADR 5: Tauri, no Electron

**Contexto:** Queriamos un editor visual para scripts `.auto` — con syntax highlighting, ejecucion integrada, preview de elementos. Un IDE minimalista. Necesitaba ser una app de escritorio porque interactua con el CLI local y el Simulador.

**Opciones:**

1. **Electron** — El estandar de la industria para apps desktop con web tech. Lo usan VS Code, Slack, Discord. Ecosistema masivo, documentacion abundante, cualquier libreria de npm funciona. Pero cada app Electron empaqueta Chromium (~200MB), consume 300-500MB de RAM base, y el backend es Node.js.

2. **Tauri** — Backend en Rust, frontend en cualquier framework web, usa el webview nativo del OS (WebKit en macOS). Binario de ~15MB. Comunidad mas pequena pero creciendo rapido. Tauri 2 trajo estabilidad significativa.

3. **App nativa SwiftUI** — Sin web, nativo puro. Minimo overhead. Pero construir un editor de codigo en SwiftUI es reinventar la rueda: syntax highlighting, autocompletado, tabs, multi-cursor — todo lo que Monaco resuelve.

**Decision:** Tauri 2 con React + TypeScript + Monaco Editor en el frontend.

**Consecuencias:**

Lo que ganamos:
- El editor completo pesa ~15MB vs ~200MB de Electron.
- Monaco nos da gratis: syntax highlighting, autocompletado, multi-cursor, minimap, busqueda y reemplazo con regex.
- El backend en Rust puede llamar al CLI `auto` directamente via `std::process::Command`.
- WebKit en macOS es rapido y consume menos memoria que Chromium embebido.

Lo que perdemos:
- Requiere Rust toolchain instalado para compilar (`rustup`). Es un requisito extra para desarrolladores.
- La comunidad de Tauri es mas pequena que la de Electron. Menos plugins, menos respuestas en Stack Overflow, menos ejemplos.
- Algunas APIs de Tauri 2 cambiaron significativamente respecto a Tauri 1. La documentacion a veces esta desactualizada.
- El webview de macOS (WebKit) tiene diferencias sutiles con Chrome. Algun CSS o API de DOM puede no funcionar identico.

---

### ADR 6: DYLD_INSERT_LIBRARIES vs force_load para camera mock

**Contexto:** Implementamos un mock de camara que reemplaza AVFoundation a nivel de ObjC runtime. La pregunta era como inyectar ese dylib en la app objetivo. Teniamos dos mecanismos de inyeccion disponibles en macOS.

**Opciones:**

1. **force_load via Xcode** — Agregas `-force_load /path/to/libCameraMock.dylib` en Other Linker Flags del proyecto. El dylib se carga al iniciar la app. Requiere acceso al proyecto Xcode y recompilar.

2. **DYLD_INSERT_LIBRARIES** — Variable de entorno que le dice al dynamic linker de macOS que cargue un dylib adicional antes de iniciar la app. No necesitas recompilar. Se pasa como argumento a `simctl launch`: `xcrun simctl launch --env DYLD_INSERT_LIBRARIES=/path/to/mock.dylib booted com.app.bundle`.

**Decision:** Soportar ambos. `force_load` para cuando tienes el proyecto y quieres integracion permanente. `DYLD_INSERT_LIBRARIES` para cuando quieres inyectar en cualquier app sin tocar su codigo.

```bash
# Opcion 1: force_load (requiere recompilar)
auto config project MiApp.xcodeproj
auto config image foto.jpg
auto build   # Agrega -force_load automaticamente

# Opcion 2: DYLD (sin recompilar)
auto launch --env DYLD_INSERT_LIBRARIES=libCameraMock.dylib
```

**Consecuencias:**

Lo que ganamos:
- Maxima flexibilidad. Si tienes el proyecto, usas force_load y es invisible. Si no tienes el proyecto (app de terceros, app precompilada en CI), usas DYLD.
- Con DYLD puedes hacer hot-swap: cambias la imagen de la camara sin recompilar ni reinstalar la app.
- El mismo dylib funciona con ambos mecanismos. No hay dos builds.

Lo que perdemos:
- DYLD_INSERT_LIBRARIES solo funciona en el Simulador. En dispositivo fisico, code signing bloquea la carga de dylibs no firmados. Esta limitacion es fundamental y no tiene workaround.
- force_load requiere acceso al proyecto Xcode. Si solo tienes el `.app` o el `.ipa`, no puedes usarlo.
- En Xcode 26, `ENABLE_DEBUG_DYLIB=NO` es necesario para que `force_load` funcione correctamente. Es un flag poco documentado que descubrimos por trial-and-error.
- Ambos mecanismos requieren que la app corra en Simulator. No hay forma de mockear la camara en un dispositivo fisico sin jailbreak.

---

### ADR 7: ObjC swizzle con #undef AV_INIT_UNAVAILABLE

**Contexto:** Para mockear la camara, necesitamos que `AVCapturePhotoOutput.capturePhoto(with:delegate:)` llame al delegate con un `AVCapturePhoto` que contenga nuestra imagen inyectada. El problema: `AVCapturePhoto` tiene `init` marcado como `NS_UNAVAILABLE` — Apple no quiere que lo instancies manualmente. Y necesitamos instanciarlo para pasar la foto al delegate.

**Opciones:**

1. **Subclase de AVCapturePhoto** — Crear `MockCapturePhoto : AVCapturePhoto`, override init. Crashea. ARM64 PAC (Pointer Authentication Codes) valida la vtable y los metodos internos que la subclase no implementa. El crash ocurre en profundidad, en metodos de CoreMedia que esperan estado interno valido.

2. **objc_msgSend directo** — Bypassear el compilador y llamar `[[AVCapturePhoto alloc] init]` via `objc_msgSend`. Mismo problema: PAC detecta que el objeto no fue inicializado por el path esperado y crashea.

3. **#undef del macro de compilacion** — AVFoundation marca init como unavailable con un macro llamado `AV_INIT_UNAVAILABLE` definido en `AVBase.h`. Si importamos `AVBase.h` primero, hacemos `#undef AV_INIT_UNAVAILABLE`, y lo redefinimos como vacio, el compilador ve `init` como un metodo normal. La instancia se crea correctamente porque ObjC runtime no valida PAC en `alloc`+`init` regular.

**Decision:** Opcion 3. Importar `AVBase.h`, `#undef AV_INIT_UNAVAILABLE`, redefinir como vacio.

```objc
#import <AVFoundation/AVBase.h>
#undef AV_INIT_UNAVAILABLE
#define AV_INIT_UNAVAILABLE

// Ahora esto compila y funciona:
AVCapturePhoto *photo = [[AVCapturePhoto alloc] init];

// Inyectamos datos via associated objects (sin tocar ivars internos):
objc_setAssociatedObject(photo, &kMockImageDataKey, imageData, OBJC_ASSOCIATION_RETAIN);
```

El truco complementario: como la instancia de `AVCapturePhoto` esta vacia (sin estado interno), no podemos usar `fileDataRepresentation` directamente — retornaria `nil`. Usamos `objc_setAssociatedObject` para adjuntar los datos de la imagen, y swizzleamos `fileDataRepresentation` para que busque primero en los associated objects antes de llamar a la implementacion original.

**Consecuencias:**

Lo que ganamos:
- `[[AVCapturePhoto alloc] init]` funciona. Podemos crear instancias reales de `AVCapturePhoto` y pasarlas al delegate como si vinieran de la camara real.
- Associated objects evitan tocar ivars internos de AVCapturePhoto. No necesitamos conocer el layout de memoria de la clase. Si Apple agrega o mueve ivars, nuestro codigo sigue funcionando.
- Los 25 metodos swizzleados cubren todo el pipeline de AVFoundation: discovery, configuracion, sesion, captura y entrega al delegate.

Lo que perdemos:
- Dependemos de que Apple no cambie el nombre del macro `AV_INIT_UNAVAILABLE`. Si lo renombran, nuestro `#undef` no hace nada y la compilacion falla. Es fragil.
- Esta tecnica solo funciona en compilacion (Clang). No podemos aplicarla en runtime — si el dylib ya esta compilado, `init` ya esta marcado como unavailable en los headers que se usaron para compilar.
- Es ObjC puro. No hay equivalente en Swift. Todo el codigo del mock de camara esta en ObjC embebido como string en `MockHeaders.swift` y compilado con `clang` en tiempo de build.
- Cualquier cambio interno en AVCapturePhoto (nuevos checks en init, validaciones de estado) podria romper esto sin aviso.

---

## Reflexion

Estas siete decisiones definen lo que AutoPilot es y lo que no es.

Es un CLI Swift nativo que habla directamente con macOS. No es cross-platform. Es un formato de scripting minimalista que prioriza legibilidad sobre poder. No es un lenguaje de programacion. Es un hack de ObjC runtime que inyecta una camara que no existe. No es una solucion elegante.

Cada decision tiene consecuencias que aceptamos con los ojos abiertos. Algunas las revisaremos — `.auto` probablemente necesitara variables y condicionales eventualmente, y Tauri podria no ser la respuesta correcta a largo plazo. Otras son permanentes — Swift y AXUIElement son la base sobre la que todo lo demas se construye.

Lo que importa no es que cada decision sea optima. Lo que importa es que cada decision este documentada con su contexto, sus alternativas y sus tradeoffs. Para nosotros en seis meses, y para cualquier ingeniero que se pregunte "¿por que no usaron XCUITest?" o "¿por que no Electron?".

La respuesta siempre esta aqui.

---

*Anterior: [Capitulo 6 — Alternativas](06-alternativas.md)*

*[Indice del libro](README.md)*
