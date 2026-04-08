# Android SDK Setup Canonico

Guia para evitar el problema mas comun: tener varios paths de Android SDK conviviendo, donde Maestro Studio, Gradle y `auto-android` apuntan a SDKs diferentes.

## El problema

En macOS suelen coexistir:

| Path | Origen | Estado tipico |
|---|---|---|
| `~/Library/Android/sdk` | Android Studio (default) | Vacio o incompleto si nunca abriste Studio |
| `/opt/homebrew/share/android-commandlinetools` | `brew install --cask android-commandlinetools` (ARM) | Completo y funcional |
| `/usr/local/share/android-commandlinetools` | Homebrew (Intel) | Completo y funcional |

Cuando tienes varios y `ANDROID_HOME` no esta seteado o apunta al equivocado, ves errores oscuros como:
- `platform-tools missing`
- `adb not found`
- Maestro Studio rechaza el SDK
- Gradle del agente no compila

## Setup canonico recomendado

### 1. Elegir UN SDK como fuente de verdad

Si ya tienes Android Studio: usa `~/Library/Android/sdk` y abre Studio una vez para que descargue platform-tools.

Si NO tienes Studio: usa el de Homebrew (`brew install --cask android-commandlinetools`).

### 2. Exportar `ANDROID_HOME` en tu shell profile

Agrega a `~/.zshrc` (o `~/.bash_profile`):

```bash
# Android Studio default
export ANDROID_HOME="$HOME/Library/Android/sdk"

# o Homebrew ARM
# export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"

export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

Reinicia la terminal o `source ~/.zshrc`.

### 3. Verificar con doctor

```bash
auto-android doctor
```

Debe mostrar:
- ✓ ANDROID_HOME apuntando al path correcto
- ✓ adb encontrado con su version
- ✓ Devices conectados (si hay emulador)

### 4. Configurar Gradle del agente

`agent/local.properties` (no commiteado, generar a mano):

```properties
sdk.dir=/Users/TU_USUARIO/Library/Android/sdk
```

O usar el de Homebrew si elegiste ese.

### 5. Configurar Maestro Studio (opcional)

En Maestro Studio: Settings → Android SDK → apuntar al mismo path que `ANDROID_HOME`.

## Que hace AutoPilot si no tienes ANDROID_HOME

`auto-android` busca adb en este orden (issue #65):

1. `$ANDROID_HOME/platform-tools/adb`
2. `$ANDROID_SDK_ROOT/platform-tools/adb` (legacy)
3. `~/Library/Android/sdk/platform-tools/adb`
4. `/opt/homebrew/share/android-commandlinetools/platform-tools/adb`
5. `/usr/local/share/android-commandlinetools/platform-tools/adb`
6. `/opt/homebrew/bin/adb`
7. `/usr/local/bin/adb`
8. `which adb` (PATH)

Esto cubre el caso de IDEs como Cursor que no heredan tu shell profile. **Pero seguir el setup canonico es mas predecible** — especialmente para Gradle y Maestro que no tienen este fallback.

## Recovery rapido si Maestro rompe el entorno

```bash
./scripts/maestro-reset.sh         # full reset
./scripts/maestro-reset.sh --soft  # solo limpia sessions corruptas
auto-android setup                 # rearma forward + agente
```

Ver `docs/benchmark/MAESTRO-RECOVERY.md` para detalles.
