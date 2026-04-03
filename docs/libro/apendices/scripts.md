# Apendice B — Guia de Scripts .auto

Los scripts `.auto` son la forma principal de automatizar flujos con AutoPilot. Un archivo `.auto` es una secuencia de comandos — uno por linea — que se ejecutan en orden. Sin YAML, sin JSON, sin XML. Una linea = un comando.

La idea detras del formato es que sea tan simple que puedas escribirlo a mano en 30 segundos. Si necesitas condicionales, bucles o logica compleja, probablemente necesitas un lenguaje de programacion real — y AutoPilot no pretende ser uno.

---

## Sintaxis basica

### Estructura de un script

```bash
# Esto es un comentario — se ignora
# Lineas vacias tambien se ignoran

comando argumento1 argumento2
otro_comando "argumento con espacios"
```

Reglas:
- **Una linea, un comando.** No hay forma de partir un comando en varias lineas.
- **Comentarios** con `#` al inicio de la linea (despues de trim de espacios).
- **Lineas vacias** se ignoran silenciosamente.
- Los comandos son exactamente los mismos que usarias en la terminal (ver [Apendice A](comandos.md)).

### Quoting

El parser respeta comillas simples y dobles para agrupar argumentos:

```bash
# Sin comillas: "tap" recibe "Sign" como argumento (no lo que queremos)
tap Sign In

# Con comillas: "tap" recibe "Sign In" como un solo argumento
tap "Sign In"

# Comillas simples tambien funcionan
type 'Hello World'

# Para elementos sin espacios, no necesitas comillas
tap Submit
```

Internamente, `tokenize()` recorre la linea caracter por caracter: cuando encuentra una comilla, agrupa todo hasta la comilla de cierre como un solo token. Fuera de comillas, los espacios separan tokens.

**Advertencia:** No hay soporte para comillas escapadas dentro de comillas (e.g., `"texto con \"comillas\""` no funciona). Si necesitas comillas literales en un texto, usa el otro tipo de comilla: `'texto con "comillas"'`.

---

## Ejecucion

### iOS

```bash
auto run scripts/examples/login-flow.auto
```

En iOS, el runner tiene un `UIStabilizer` integrado: antes de cada paso, espera a que la UI se estabilice (0.3s sin cambios en el arbol AX, timeout 3s). Esto significa que rara vez necesitas `wait` explicitos entre comandos.

### Android

```bash
auto-android run scripts/examples/android-login.auto
```

En Android no hay UIStabilizer (el agente nativo responde cuando la UI esta lista), asi que los comandos se ejecutan uno tras otro. Si la UI tarda en cargar, necesitas `waitFor` explicitos.

### Cross-platform

La promesa de AutoPilot es que **el mismo script funciona en ambas plataformas**. Cambias el binario, no el script:

```bash
# iOS
auto run scripts/examples/login.auto

# Android — mismo archivo
auto-android run scripts/examples/login.auto
```

Esto funciona porque ambos binarios implementan el protocolo `DeviceBridge` con los mismos 22 metodos. `tap`, `waitFor`, `screenshot`, `swipe` — todos se comportan igual.

**Limitacion:** Los comandos que solo existen en una plataforma (`camera`, `inject`, `build`, `index`, `inspect`) haran que el script falle en la otra. Si tu flujo necesita esos comandos, mantenlo como script especifico de plataforma.

---

## Patrones y buenas practicas

### 1. Siempre `waitFor` antes de interactuar

```bash
# MAL — tap puede fallar si la pantalla no ha cargado
launch com.example.app
tap "Login"

# BIEN — esperar a que el elemento exista
launch com.example.app
waitFor "Login" 10
tap "Login"
```

El `waitFor` hace polling cada 500ms hasta que encuentra el elemento o se acaba el timeout. Si el timeout se cumple, el script termina con `exit(1)`.

### 2. Screenshot como evidencia

```bash
waitFor "Welcome" 10
screenshot /tmp/01-welcome.png

tap "Profile"
waitFor "Settings" 5
screenshot /tmp/02-profile.png
```

Nombra los screenshots con un prefijo numerico para que se ordenen cronologicamente. Esto es especialmente util en CI/CD donde no puedes ver la pantalla.

### 3. Prefijo numerico para screenshots

Un patron que usamos en todos los scripts de produccion:

```bash
screenshot /tmp/01-auth-screen.png
screenshot /tmp/02-pin-entered.png
screenshot /tmp/03-home.png
screenshot /tmp/04-filtered.png
```

En CI, estos screenshots se suben como artefactos y puedes reconstruir visualmente que paso en cada paso.

### 4. `wait` para estabilizar UI

```bash
biometric enroll
wait 1
launch com.example.app
wait 1
waitFor "Unlock with Face ID" 10
```

Algunos comandos (como `biometric enroll`) cambian estado del dispositivo pero la UI no se actualiza instantaneamente. Un `wait 1` da tiempo al sistema.

### 5. `terminate` antes de `launch` para estado limpio

```bash
# Asegurar que la app no tiene estado residual
terminate com.example.app
wait 1
launch com.example.app
waitFor "Login" 10
```

---

## Ejemplo completo: flujo de login

Este script autentica a un usuario en una app que tiene pantalla de login con PIN. Funciona en iOS y Android.

```bash
# login.auto
# Flujo: launch → PIN auth → verificar home → navegar
#
# Uso:
#   auto run login.auto
#   auto-android run login.auto

# 1. Lanzar la app
launch dev.autopilot.test.Explorea
waitFor "Explorea" 10
screenshot /tmp/01-auth.png
```

**Linea por linea:**
- `launch` arranca la app por su bundle/package ID.
- `waitFor "Explorea" 10` espera hasta 10 segundos a que aparezca un elemento con texto "Explorea". Si la app tarda en arrancar (cold start), el timeout lo absorbe.
- `screenshot` captura evidencia del estado actual.

```bash
# 2. Autenticacion con PIN
tap "Desbloquear con codigo"
waitFor "Ingresa tu codigo" 5
tap "1"
tap "2"
tap "3"
tap "4"
screenshot /tmp/02-code-entered.png
```

**Linea por linea:**
- `tap "Desbloquear con codigo"` busca un elemento con ese texto y hace tap. Las comillas son necesarias porque hay espacios.
- Los `tap "1"`, `tap "2"`, etc. tocan los botones del teclado numerico. Cada uno es un tap independiente.
- No hay `waitFor` entre los taps del PIN porque los botones ya estan en pantalla. El `waitFor` inicial garantizo que la UI cargo.

```bash
# 3. Verificar home y navegar
waitFor "Inicio" 5
screenshot /tmp/03-home.png

tap "Aventura"
screenshot /tmp/04-filtered.png

swipe up
screenshot /tmp/05-scrolled.png
```

**Linea por linea:**
- `waitFor "Inicio" 5` verifica que la autenticacion fue exitosa — esperamos la pantalla principal.
- `tap "Aventura"` filtra contenido por categoria.
- `swipe up` hace scroll hacia arriba (el gesto va hacia arriba, el contenido se mueve hacia abajo).

---

## Errores comunes y como resolverlos

### "No elements found matching 'X'"

**Causa:** El texto que buscas no coincide exactamente con el que tiene el elemento en el arbol AX.

**Solucion:** Usa `auto tree -s "X"` para ver que elementos existen. A veces el label es diferente del texto visible (e.g., un boton muestra "Sign In" pero su `accessibilityIdentifier` es "signInButton").

```bash
# Depurar
auto tree -s "Sign"
# Ver todo el arbol
auto tree
```

### "Timeout: 'X' not found after 10s"

**Causa:** El elemento no aparecio dentro del timeout de `waitFor`.

**Posibles razones:**
1. La app no termino de cargar (aumenta el timeout)
2. El texto cambio entre versiones de la app
3. La pantalla esperada nunca aparecio (error en la logica del flujo)

**Solucion:** Agrega un `screenshot` justo antes del `waitFor` para ver en que estado esta la UI:

```bash
screenshot /tmp/debug-before-wait.png
waitFor "Welcome" 15
```

### "FAIL at line N: ..."

**Causa:** Un comando fallo durante la ejecucion del script. El runner imprime el numero de linea y el error, luego sale con `exit(1)`.

**Solucion:** El numero de linea apunta a la linea del archivo `.auto` (incluyendo comentarios y lineas vacias). Abre el archivo y ve que comando esta en esa linea.

### La app se queda en un estado inesperado

**Solucion:** Agrega `terminate` + `launch` al inicio del script para garantizar estado limpio:

```bash
terminate com.example.app
wait 1
launch com.example.app
waitFor "Login" 10
```

### Tap no hace nada (no falla, pero no pasa nada)

**Causa posible en iOS:** Algunos elementos de SwiftUI (especialmente botones en NavigationBar) no se exponen correctamente via macOS Accessibility. `tree` puede mostrar `AXChildren=[0]` para el NavigationBar.

**Solucion:** Usa `auto inspect "NavigationBar"` para debug profundo. Si el elemento realmente no esta expuesto, usa `tapAt <x> <y>` como workaround con coordenadas absolutas.

### El script funciona en iOS pero no en Android (o viceversa)

**Causa:** Estas usando un comando que solo existe en una plataforma (`camera`, `inject`, `build`, `index`, `inspect` son solo iOS).

**Solucion:** Mantiene los comandos cross-platform: `tap`, `waitFor`, `screenshot`, `swipe`, `launch`, `terminate`, `biometric`, `wait`, `type`, `exists`.

---

## Referencia rapida del formato

```
# Comentario
comando                          # Sin argumentos
comando argumento                # Un argumento
comando "argumento con espacios" # Quoting con comillas dobles
comando 'otro argumento'         # Quoting con comillas simples
comando a,b,c                    # Multi-tap (especifico de tap)
```

El parser (`ScriptParser.swift`) es deliberadamente minimalista: ~50 lineas de codigo. No hay variables, no hay condicionales, no hay macros. Si el formato se siente limitante, es intencional — la complejidad pertenece al codigo Swift, no al script.

---

**Ver tambien:**
- [Apendice A — Referencia de Comandos](comandos.md) para la lista completa de comandos disponibles
- [Capitulo 2 — Arquitectura](../02-arquitectura.md) para entender como funciona `DeviceBridge`
- [Capitulo 9 — El agente Android](../09-el-agente-android.md) para las diferencias de ejecucion entre plataformas
