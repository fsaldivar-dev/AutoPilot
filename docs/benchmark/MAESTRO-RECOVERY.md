# Maestro Recovery — Guia de troubleshooting

## Cuando usar este documento

Cuando Maestro entra en uno de estos estados:

- Error 7001
- `Driver startup timeout`
- Tests cuelgan al iniciar el driver
- `dev.mobile.maestro` no responde
- Conflicto con `io.appium.uiautomator2.server` (instalado por Appium previamente)

## Recovery rapido

### Soft reset (primer intento — solo limpia sessions)

```bash
./scripts/maestro-reset.sh --soft
export MAESTRO_DRIVER_STARTUP_TIMEOUT=180000
maestro test --device emulator-5554 tu-flow.yaml
```

Esto:
- Borra `~/.maestro/sessions/*` (sesiones corruptas)
- Aumenta el timeout a 3 minutos

### Hard reset (segundo intento — desinstala paquetes)

```bash
./scripts/maestro-reset.sh
export MAESTRO_DRIVER_STARTUP_TIMEOUT=180000
maestro test --device emulator-5554 --reinstall-driver tu-flow.yaml
```

Esto adicionalmente:
- Desinstala `dev.mobile.maestro` y `dev.mobile.maestro.test` del emulador
- Desinstala `io.appium.uiautomator2.server*` (conflicto comun)
- Maestro reinstala el driver en el siguiente run

## Tras correr Maestro, volver a AutoPilot

Maestro hace `adb kill-server` y resetea forwards. Para volver a `auto-android`:

```bash
auto-android setup
```

Esto rearma `adb forward tcp:9008 localabstract:autopilot` + relanza el agente.
Ver `auto-android doctor` para verificar.

## Convivencia Maestro ↔ AutoPilot en la misma sesion

**Recomendacion**: no correr ambos a la vez sobre el mismo emulador.

Si necesitas alternar:

1. Antes de Maestro: nada especial, Maestro arranca su propio driver
2. Despues de Maestro, volviendo a AutoPilot: `auto-android setup`
3. Si algo se atasca: `./scripts/maestro-reset.sh` + reintentar

## Errores conocidos

| Error | Causa | Fix |
|---|---|---|
| `Driver startup timeout` | Driver no arranca a tiempo | `MAESTRO_DRIVER_STARTUP_TIMEOUT=180000` + `--reinstall-driver` |
| `7001` | Sessions corruptas | `./scripts/maestro-reset.sh --soft` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Conflicto con driver Appium | `./scripts/maestro-reset.sh` (hard) |
| `Cannot connect to agent` (en auto-android tras Maestro) | adb forward perdido | `auto-android setup` |
