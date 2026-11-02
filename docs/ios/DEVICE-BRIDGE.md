# Bridge XCUI en iPhone FÍSICO (prototipo de ARD-002 / #114)

> Cómo correr el runner XCUI de AutoPilot en un **iPhone físico** y manejarlo desde la Mac por USB,
> sin cambiar el protocolo. Es un prototipo end-to-end de la Fase 3 (device físico). Validado en un
> iPhone 15 Pro con iOS 27 (Xcode 27).

## El fix de raíz

El runner (`RunnerServer.swift`) abría su socket TCP en **`127.0.0.1` (loopback-only)**. Eso funciona en el
Simulador porque comparte el loopback con el host, pero **en device físico `usbmux`/`iproxy` NO alcanza un
servicio loopback-only** → el forward-port devuelve `Connection refused`.

Fix: en device, escuchar en **`0.0.0.0` (INADDR_ANY)**; en simulador se mantiene `127.0.0.1` (más seguro):

```swift
#if targetEnvironment(simulator)
addr.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian // 127.0.0.1
#else
addr.sin_addr.s_addr = in_addr_t(0)                    // 0.0.0.0 (alcanzable por iproxy en device)
#endif
```

## Receta end-to-end

Requisitos: `brew install libimobiledevice` (trae `iproxy`), cuenta de Apple Developer logueada en Xcode,
e iPhone con **Modo desarrollador** + **Ajustes → Desarrollador → "Enable UI Automation" ON** (sin esto:
`Timed out while enabling automation mode`).

```bash
DEV=<device-udid>          # xcrun devicectl list devices
TEAM=<development-team-id>

# 1) Compilar el runner firmado para el device (limpiar perfil manual del Demo si lo trae)
xcodebuild build-for-testing \
  -project "Demo/iOS/Test Automatitacion/Test Automatitacion.xcodeproj" \
  -scheme "Test Automatitacion" \
  -destination "platform=iOS,id=$DEV" \
  -derivedDataPath /tmp/apdd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM \
  CODE_SIGN_STYLE=Automatic PROVISIONING_PROFILE_SPECIFIER="" PROVISIONING_PROFILE=""

# 2) Correr el runner (se queda sirviendo; abre 22087 en el iPhone)
xcodebuild test-without-building \
  -xctestrun /tmp/apdd/Build/Products/*.xctestrun \
  -destination "platform=iOS,id=$DEV" \
  -only-testing:"Test AutomatitacionUITests/AutoPilotRunnerTests/testServe" &

# 3) Forward-port USB: localhost:22087 -> iPhone:22087
iproxy -u $DEV 22087:22087 &

# 4) Manejar con el MISMO protocolo JSON (params anidados). Ej. en Python:
python3 - <<'PY'
import socket, json
def cmd(d):
    s=socket.create_connection(('127.0.0.1',22087), timeout=20)
    s.sendall((json.dumps(d)+'\n').encode()); r=s.recv(1<<20); s.close(); return r.decode()
print(cmd({"method":"ping"}))
print(cmd({"method":"launch","params":{"bundleId":"com.example.app"}}))
print(cmd({"method":"tap","params":{"target":"Omitir"}}))
PY
```

Nota: `nc` no lee bien la respuesta por su half-close; usar un cliente TCP (connect/send/recv).

## Limitaciones conocidas (para endurecer en #114)

- **Pantallas con actividad en vivo tumban el runner en device.** Una vista con un *listener* en tiempo real
  (p. ej. Firestore `addSnapshotListener` de disponibilidad) mantiene la app "ocupada" y XCUITest nunca se
  "asienta" → el proceso de test termina con fallo justo al aparecer esa pantalla (reproducible: muere al
  tocar el botón que navega a ella, antes de cualquier captura). Workaround temporal: evitar esa pantalla en
  automatización. Fix de fondo pendiente: desactivar el idle-wait de XCUITest o aislar el snapshot.
- **Face ID / passcode** son muros biométricos del sistema: la automatización llega hasta la hoja y el humano
  completa la autenticación (correcto por diseño de Apple).
