# Casos de Prueba - Explorea

## Modulo 1: Autenticacion

### CP-001: Desbloqueo exitoso con Face ID
**Precondicion:** App cerrada, usuario no autenticado
**Pasos:**
1. Abrir la aplicacion Explorea
2. Verificar que se muestra la pantalla de bienvenida con el logo y el nombre "Explorea"
3. Tocar el boton "Desbloquear con Face ID"
4. Autenticarse exitosamente con Face ID

**Resultado esperado:** La pantalla transiciona con animacion hacia la pantalla principal mostrando el tab "Inicio" con las entradas del diario de viajes.

---

### CP-002: Face ID fallido muestra error
**Precondicion:** App en pantalla de login
**Pasos:**
1. Tocar "Desbloquear con Face ID"
2. Fallar la autenticacion biometrica (cara no reconocida)

**Resultado esperado:** Se muestra un mensaje de error debajo del boton y aparece la opcion de "Usar PIN" como alternativa.

---

### CP-003: Desbloqueo con PIN correcto
**Precondicion:** App en pantalla de login
**Pasos:**
1. Tocar "Usar PIN"
2. Verificar que aparece el teclado numerico con 4 circulos indicadores
3. Ingresar el PIN "1234" tocando los digitos uno por uno
4. Verificar que los circulos se llenan conforme se ingresan digitos
5. Tocar "Confirmar"

**Resultado esperado:** El usuario accede a la pantalla principal exitosamente.

---

### CP-004: PIN incorrecto muestra error
**Precondicion:** Pantalla de PIN visible
**Pasos:**
1. Ingresar el PIN "0000"
2. Tocar "Confirmar"

**Resultado esperado:** Se muestra el mensaje "PIN incorrecto", los circulos se vacian y el campo de PIN se limpia para reintentar.

---

### CP-005: Borrar digitos del PIN
**Precondicion:** Pantalla de PIN visible con al menos 2 digitos ingresados
**Pasos:**
1. Ingresar "12"
2. Tocar el boton de borrar (icono de delete)
3. Verificar que queda solo 1 circulo lleno
4. Ingresar "234" para completar "1234"
5. Confirmar

**Resultado esperado:** El digito se borra correctamente, los circulos reflejan la cantidad actual de digitos, y al completar el PIN correcto se accede a la app.

---

### CP-006: Alternar entre Face ID y PIN
**Precondicion:** Pantalla de login
**Pasos:**
1. Tocar "Usar PIN" - verificar que aparece el teclado numerico
2. Tocar "Usar Face ID" - verificar que vuelve al boton de Face ID
3. Repetir el cambio 2 veces mas

**Resultado esperado:** La interfaz cambia suavemente entre ambos modos de autenticacion sin perder estado visual.

---

## Modulo 2: Pantalla de Inicio

### CP-007: Visualizar entradas del diario
**Precondicion:** Usuario autenticado, datos de ejemplo cargados
**Pasos:**
1. Verificar que la pantalla muestra el titulo "Mis Viajes"
2. Verificar que la primera entrada se muestra como tarjeta grande (hero card)
3. Hacer scroll hacia abajo para ver las demas entradas en formato compacto
4. Verificar que cada tarjeta muestra: titulo, ubicacion, emoji de mood y categoria

**Resultado esperado:** Se muestran 7 entradas de ejemplo. La primera como hero card con gradiente de color y las demas como tarjetas compactas con icono de categoria.

---

### CP-008: Buscar entradas por texto
**Precondicion:** Pantalla de inicio con entradas visibles
**Pasos:**
1. Tocar la barra de busqueda "Buscar destinos, experiencias..."
2. Escribir "Santorini"
3. Verificar que solo se muestra la entrada "Atardecer en Santorini"
4. Limpiar la busqueda
5. Escribir "tacos"
6. Verificar que se muestra "Tacos al pastor en CDMX"
7. Escribir "xyz123" (texto sin resultados)

**Resultado esperado:** La lista se filtra en tiempo real. Con "xyz123" se muestra el estado vacio con el mensaje "No hay viajes aun".

---

### CP-009: Filtrar por categoria
**Precondicion:** Pantalla de inicio
**Pasos:**
1. Hacer scroll horizontal en los chips de categoria
2. Tocar "Gastronomia"
3. Verificar que solo se muestran entradas de esa categoria
4. Tocar "Cultura"
5. Verificar que cambia el filtro
6. Tocar "Todos" para quitar el filtro

**Resultado esperado:** Los chips cambian de estilo al seleccionarse (fondo gradiente, texto blanco) y la lista se filtra instantaneamente.

---

### CP-010: Filtro de solo favoritos
**Precondicion:** Pantalla de inicio con entradas
**Pasos:**
1. Activar el toggle "Solo favoritos"
2. Verificar que solo se muestran las entradas marcadas como favoritas
3. Desactivar el toggle

**Resultado esperado:** La lista se actualiza mostrando solo las entradas con corazon. Al desactivar, vuelven todas.

---

### CP-011: Pull to refresh
**Precondicion:** Pantalla de inicio
**Pasos:**
1. Hacer pull-to-refresh (arrastrar hacia abajo desde la parte superior de la lista)
2. Verificar que aparece el indicador de carga
3. Esperar a que termine

**Resultado esperado:** El indicador de refresh aparece, gira brevemente y desaparece.

---

### CP-012: Menu contextual en entrada (long press)
**Precondicion:** Pantalla de inicio con entradas
**Pasos:**
1. Mantener presionada una entrada (long press) durante 1-2 segundos
2. Verificar que aparece un menu contextual con opciones
3. Seleccionar "Favorito" para marcar/desmarcar como favorito
4. Repetir el long press y seleccionar "Copiar"
5. Repetir y seleccionar "Eliminar"

**Resultado esperado:** El menu contextual muestra 3 opciones (Favorito, Copiar, Eliminar). Favorito cambia el estado del corazon, Copiar copia el titulo y ubicacion, Eliminar pide confirmacion antes de borrar.

---

### CP-013: Navegar al detalle de una entrada
**Precondicion:** Pantalla de inicio con entradas
**Pasos:**
1. Tocar la entrada "Noche en Shibuya"
2. Verificar que se navega a la pantalla de detalle

**Resultado esperado:** Se muestra la vista de detalle con header grande mostrando el color de la categoria, titulo, ubicacion, fecha, mood, descripcion completa y un mapa con la ubicacion de Tokio.

---

## Modulo 3: Detalle de Entrada

### CP-014: Visualizar detalle completo
**Precondicion:** Dentro del detalle de "Atardecer en Santorini"
**Pasos:**
1. Verificar la cabecera con gradiente verde (categoria Naturaleza)
2. Verificar el titulo "Atardecer en Santorini"
3. Verificar la seccion de metadatos (ubicacion, fecha, mood emoji)
4. Verificar la descripcion completa
5. Hacer scroll hasta ver el mapa con un pin en Santorini
6. Verificar las acciones disponibles al final

**Resultado esperado:** Todos los datos de la entrada se muestran correctamente incluyendo el mapa con el pin en las coordenadas de Santorini, Grecia.

---

### CP-015: Agregar/quitar favorito desde detalle
**Precondicion:** Detalle de una entrada
**Pasos:**
1. Tocar "Agregar a favoritos"
2. Verificar que el boton cambia a "Quitar de favoritos" con estilo resaltado
3. Tocar "Quitar de favoritos"
4. Verificar que vuelve al estado original

**Resultado esperado:** El boton cambia de estado y estilo visual correctamente. El cambio se refleja tambien en la pantalla de inicio.

---

### CP-016: Copiar al portapapeles desde detalle
**Precondicion:** Detalle de una entrada
**Pasos:**
1. Tocar "Copiar al portapapeles"
2. Ir a Perfil > seccion Portapapeles

**Resultado esperado:** Se muestra el contenido copiado en la seccion de portapapeles del perfil.

---

### CP-017: Eliminar entrada con confirmacion
**Precondicion:** Detalle de cualquier entrada, anotar cuantas entradas hay en total
**Pasos:**
1. Tocar "Eliminar entrada"
2. Verificar que aparece un dialogo de confirmacion con mensaje de advertencia
3. Tocar "Cancelar" - verificar que no se borra nada
4. Tocar "Eliminar entrada" de nuevo
5. Tocar "Eliminar" en el dialogo

**Resultado esperado:** Al cancelar no pasa nada. Al confirmar, se regresa a la pantalla de inicio y la entrada ya no aparece en la lista.

---

### CP-018: Zoom en foto (pinch to zoom)
**Precondicion:** Detalle de una entrada que tiene fotos adjuntas
**Pasos:**
1. Tocar una de las fotos en la seccion de fotos
2. Verificar que se abre el visor de fotos a pantalla completa
3. Hacer pinch-to-zoom para acercar la imagen
4. Hacer doble tap para hacer zoom
5. Hacer doble tap otra vez para volver al tamano original
6. Tocar "Cerrar"

**Resultado esperado:** La foto se muestra en pantalla completa, el zoom funciona con gestos de pellizco y doble toque, y se cierra correctamente.

---

## Modulo 4: Crear Nueva Entrada

### CP-019: Abrir formulario de nueva entrada
**Precondicion:** Pantalla principal autenticada
**Pasos:**
1. Tocar el boton "+" (FAB) en la barra de tabs

**Resultado esperado:** Se abre un sheet con el formulario "Nueva Entrada" con barra de navegacion que incluye "Cancelar" y "Guardar".

---

### CP-020: Crear entrada completa
**Precondicion:** Formulario de nueva entrada abierto
**Pasos:**
1. En la seccion Fotos, tocar "Galeria" y seleccionar 2 fotos
2. Ingresar titulo: "Mi primer viaje de prueba"
3. Ingresar descripcion: "Esta es una descripcion de prueba para validar la creacion de entradas en el diario."
4. Seleccionar categoria "Aventura" tocando el icono correspondiente
5. Ingresar ubicacion: "Madrid, Espana"
6. Cambiar la fecha usando el date picker
7. Mover el slider de mood al maximo (emoji debe mostrar cara emocionada)
8. Activar el toggle "Marcar como favorito"
9. Tocar "Guardar"

**Resultado esperado:** La entrada se guarda exitosamente, el sheet se cierra, y la nueva entrada aparece al inicio de la lista en la pantalla de inicio con todos los datos ingresados.

---

### CP-021: Validacion de campos requeridos
**Precondicion:** Formulario de nueva entrada abierto
**Pasos:**
1. Dejar todos los campos vacios
2. Verificar que el boton "Guardar" esta deshabilitado (opaco)
3. Llenar solo el titulo
4. Verificar que "Guardar" sigue deshabilitado
5. Llenar titulo, descripcion y ubicacion
6. Verificar que "Guardar" se habilita

**Resultado esperado:** El boton "Guardar" solo se activa cuando titulo, descripcion y ubicacion estan completos.

---

### CP-022: Tomar foto con camara
**Precondicion:** Formulario de nueva entrada, dispositivo con camara
**Pasos:**
1. Tocar "Camara" en la seccion de fotos
2. Se abre la camara del sistema
3. Tomar una foto
4. Confirmar la foto (usar foto / retomar)
5. Verificar que la foto aparece en la seccion de fotos del formulario

**Resultado esperado:** La foto capturada se muestra como miniatura en el formulario, con un boton X para eliminarla.

---

### CP-023: Eliminar foto del formulario
**Precondicion:** Formulario con al menos una foto agregada
**Pasos:**
1. Tocar el boton X en la esquina de una foto
2. Verificar que la foto desaparece de la lista

**Resultado esperado:** La foto se elimina con animacion.

---

### CP-024: Seleccionar categoria con retroalimentacion visual
**Precondicion:** Formulario de nueva entrada
**Pasos:**
1. Tocar la categoria "Gastronomia" - verificar que se resalta con color solido
2. Tocar "Cultura" - verificar que cambia la seleccion
3. Recorrer todas las categorias una por una

**Resultado esperado:** Solo una categoria puede estar seleccionada a la vez. La seleccionada muestra circulo con color solido y la etiqueta cambia de color.

---

### CP-025: Slider de mood
**Precondicion:** Formulario de nueva entrada
**Pasos:**
1. Mover el slider de mood al minimo (0) - verificar emoji dormido
2. Mover a 1 - verificar emoji neutral
3. Mover a 3 - verificar emoji sonriente
4. Mover al maximo (5) - verificar emoji emocionado

**Resultado esperado:** El emoji cambia en tiempo real conforme se mueve el slider, mostrando la progresion de emociones.

---

### CP-026: Cancelar creacion de entrada
**Precondicion:** Formulario de nueva entrada con datos parcialmente llenados
**Pasos:**
1. Llenar titulo y descripcion
2. Tocar "Cancelar"

**Resultado esperado:** El formulario se cierra sin guardar nada. La lista de entradas en inicio permanece igual.

---

## Modulo 5: Captura (Camara y QR)

### CP-027: Cambiar entre modo Fotos y Escaner QR
**Precondicion:** Tab "Capturar" activo
**Pasos:**
1. Verificar que el segmented control muestra "Fotos" y "Escaner QR"
2. Tocar "Escaner QR"
3. Verificar que la vista cambia al escaner
4. Tocar "Fotos"
5. Verificar que vuelve a la vista de fotos

**Resultado esperado:** El segmented control alterna las vistas correctamente con transicion suave.

---

### CP-028: Capturar foto desde tab Capturar
**Precondicion:** Tab Capturar en modo Fotos
**Pasos:**
1. Tocar el boton grande circular de captura (gradiente rojo-naranja)
2. Se abre la camara del sistema
3. Tomar una foto y confirmar
4. Verificar que la foto aparece en "Fotos capturadas" en la parte inferior

**Resultado esperado:** La foto se agrega a la galeria inferior con un contador actualizado (ej. "3 fotos").

---

### CP-029: Toggle de flash
**Precondicion:** Tab Capturar en modo Fotos
**Pasos:**
1. Tocar el boton de Flash (icono de rayo)
2. Verificar que el icono cambia a rayo activo (amarillo)
3. Tocar de nuevo
4. Verificar que vuelve al estado apagado

**Resultado esperado:** El icono alterna entre rayo activo (amarillo) y rayo tachado (gris).

---

### CP-030: Seleccionar fotos de galeria desde tab Capturar
**Precondicion:** Tab Capturar en modo Fotos
**Pasos:**
1. Tocar el boton "Galeria"
2. Seleccionar 3 fotos del picker del sistema
3. Confirmar seleccion

**Resultado esperado:** Las 3 fotos se agregan a la seccion "Fotos capturadas".

---

### CP-031: Ver foto capturada en detalle
**Precondicion:** Tab Capturar con al menos una foto capturada
**Pasos:**
1. Tocar una foto de la galeria de capturas
2. Verificar que se abre el visor a pantalla completa
3. Cerrar el visor

**Resultado esperado:** La foto se muestra a pantalla completa con fondo negro y boton de cerrar.

---

### CP-032: Escanear codigo QR
**Precondicion:** Tab Capturar en modo Escaner QR, dispositivo con camara
**Pasos:**
1. Verificar que se muestra la vista de la camara con un recuadro de escaneo
2. Apuntar a un codigo QR
3. Verificar que aparece una alerta con el contenido del QR

**Resultado esperado:** Se detecta el QR, aparece alerta "Codigo QR Detectado" con el contenido y opciones "Copiar", "Guardar" y "Cerrar".

---

### CP-033: Guardar resultado de QR
**Precondicion:** Alerta de QR detectado visible
**Pasos:**
1. Tocar "Guardar"
2. Verificar que el codigo aparece en la lista "Codigos escaneados" debajo del escaner

**Resultado esperado:** El QR se agrega a la lista con su contenido, fecha y hora. Aparece un boton de copiar junto a cada resultado.

---

### CP-034: Copiar resultado de QR
**Precondicion:** Al menos un QR guardado en la lista
**Pasos:**
1. Tocar el icono de copiar junto a un resultado QR
2. Ir a Perfil > Portapapeles
3. Verificar que el contenido del QR esta ahi

**Resultado esperado:** El contenido se copia exitosamente al portapapeles de la app.

---

### CP-035: Eliminar resultado QR con swipe
**Precondicion:** Lista de QR escaneados con al menos un resultado
**Pasos:**
1. Hacer swipe a la izquierda sobre un resultado QR
2. Tocar "Delete"

**Resultado esperado:** El resultado se elimina de la lista con animacion.

---

## Modulo 6: Mapa

### CP-036: Visualizar mapa con pines de entradas
**Precondicion:** Tab Mapa activo, entradas con coordenadas existentes
**Pasos:**
1. Verificar que el mapa muestra pines de colores en diferentes ubicaciones del mundo
2. Verificar que los colores de los pines corresponden a la categoria de cada entrada
3. Hacer zoom out para ver todos los pines

**Resultado esperado:** Se muestran 7 pines con los iconos de categoria en colores correspondientes (verde para naturaleza, rojo para comida, etc.).

---

### CP-037: Tocar pin y ver detalle
**Precondicion:** Mapa con pines visibles
**Pasos:**
1. Tocar un pin (ej. Santorini)
2. Verificar que se abre un sheet con el detalle de la entrada

**Resultado esperado:** Se abre un sheet con presentacion parcial (medium/large) mostrando el detalle completo de la entrada.

---

### CP-038: Cambiar estilo de mapa
**Precondicion:** Tab Mapa activo
**Pasos:**
1. Verificar el segmented control con "Estandar", "Satelite", "Hibrido"
2. Seleccionar "Satelite"
3. Verificar que el mapa cambia a vista satelital
4. Seleccionar "Hibrido"
5. Verificar la vista hibrida
6. Volver a "Estandar"

**Resultado esperado:** El mapa cambia de estilo visualmente entre las tres opciones.

---

### CP-039: Estadisticas en overlay del mapa
**Precondicion:** Tab Mapa activo
**Pasos:**
1. Verificar el overlay semitransparente en la parte inferior
2. Verificar que muestra "Lugares", "Ciudades" y "Favoritos" con conteos correctos

**Resultado esperado:** Los numeros reflejan las estadisticas reales de las entradas.

---

### CP-040: Boton de ubicacion del usuario
**Precondicion:** Tab Mapa, permisos de ubicacion otorgados
**Pasos:**
1. Tocar el boton de ubicacion del usuario (icono de flecha)
2. Verificar que el mapa centra en la ubicacion actual

**Resultado esperado:** El mapa se desplaza y centra en la ubicacion actual del dispositivo.

---

## Modulo 7: Perfil y Configuracion

### CP-041: Cambiar foto de perfil con camara
**Precondicion:** Tab Perfil activo
**Pasos:**
1. Tocar el avatar (circulo con inicial del nombre)
2. Verificar que aparece un action sheet con opciones
3. Seleccionar "Tomar foto"
4. Tomar una foto y confirmar

**Resultado esperado:** El avatar se actualiza con la foto tomada.

---

### CP-042: Cambiar foto de perfil desde galeria
**Precondicion:** Tab Perfil
**Pasos:**
1. Tocar el avatar
2. Seleccionar "Elegir de galeria"
3. Seleccionar una foto

**Resultado esperado:** El avatar se actualiza con la foto seleccionada.

---

### CP-043: Eliminar foto de perfil
**Precondicion:** Perfil con foto de avatar establecida
**Pasos:**
1. Tocar el avatar
2. Seleccionar "Eliminar foto"

**Resultado esperado:** El avatar vuelve al estado por defecto (circulo con gradiente y la inicial del nombre).

---

### CP-044: Editar nombre y email
**Precondicion:** Tab Perfil
**Pasos:**
1. Tocar el campo de nombre
2. Borrar "Viajero" y escribir "Francisco"
3. Tocar el campo de email
4. Escribir "francisco@example.com"
5. Verificar que el avatar muestra la letra "F"

**Resultado esperado:** Los campos se actualizan, el avatar refleja la nueva inicial.

---

### CP-045: Activar notificaciones
**Precondicion:** Tab Perfil, notificaciones desactivadas
**Pasos:**
1. Activar el toggle "Notificaciones"
2. Si aparece dialogo del sistema solicitando permisos, aceptar
3. Verificar que aparece el date picker "Recordatorio diario"
4. Cambiar la hora del recordatorio

**Resultado esperado:** Al activar notificaciones aparece el selector de hora. El sistema solicita permiso de notificaciones.

---

### CP-046: Desactivar notificaciones
**Precondicion:** Notificaciones activadas
**Pasos:**
1. Desactivar el toggle "Notificaciones"
2. Verificar que desaparece el date picker de hora

**Resultado esperado:** El toggle se desactiva y el selector de hora se oculta.

---

### CP-047: Cambiar preferencias (metrico, modo oscuro)
**Precondicion:** Tab Perfil
**Pasos:**
1. Activar el toggle "Modo oscuro"
2. Verificar que toda la app cambia a tema oscuro
3. Desactivar "Modo oscuro"
4. Toggle "Sistema metrico" - verificar que cambia de estado

**Resultado esperado:** El modo oscuro afecta toda la app inmediatamente. El toggle metrico cambia su estado visual.

---

### CP-048: Ver estadisticas del perfil
**Precondicion:** Tab Perfil con entradas existentes
**Pasos:**
1. Verificar la seccion "Estadisticas"
2. Verificar "Total de entradas" = 7
3. Verificar "Ciudades visitadas" = 7
4. Verificar "Favoritos" = 4
5. Verificar "Fotos capturadas" muestra el conteo actual
6. Verificar "Categoria favorita" muestra la categoria mas usada

**Resultado esperado:** Los numeros reflejan los datos reales de la app.

---

### CP-049: Portapapeles - pegar del sistema
**Precondicion:** Texto copiado en el portapapeles del sistema
**Pasos:**
1. Ir a la seccion "Portapapeles" en Perfil
2. Tocar "Pegar del sistema"
3. Si aparece dialogo del sistema pidiendo permiso, aceptar

**Resultado esperado:** El texto del portapapeles del sistema se muestra en la seccion.

---

### CP-050: Exportar datos (simulado)
**Precondicion:** Tab Perfil
**Pasos:**
1. Tocar "Exportar mis datos"
2. Verificar que aparece una alerta de confirmacion

**Resultado esperado:** Aparece alerta indicando cuantas entradas se exportaron (demo).

---

### CP-051: Cerrar sesion
**Precondicion:** Tab Perfil, usuario autenticado
**Pasos:**
1. Tocar "Cerrar sesion"
2. Verificar que aparece un dialogo de confirmacion con mensaje de advertencia
3. Tocar "Cancelar" - verificar que no pasa nada
4. Tocar "Cerrar sesion" de nuevo
5. Confirmar la accion

**Resultado esperado:** Al confirmar, la app regresa a la pantalla de login con Face ID / PIN. Los datos se mantienen para cuando vuelva a autenticarse.

---

## Modulo 8: Navegacion y Tab Bar

### CP-052: Navegacion entre tabs
**Precondicion:** Usuario autenticado en pantalla principal
**Pasos:**
1. Tocar tab "Inicio" - verificar pantalla de inicio
2. Tocar tab "Capturar" - verificar pantalla de captura
3. Tocar tab "Mapa" - verificar pantalla de mapa
4. Tocar tab "Perfil" - verificar pantalla de perfil
5. Tocar el boton central "+" - verificar que abre formulario de nueva entrada

**Resultado esperado:** Cada tab muestra su pantalla correspondiente. El boton "+" abre un sheet. El tab seleccionado se resalta en rojo.

---

### CP-053: Tab bar persiste en todas las pantallas principales
**Precondicion:** Cualquier tab activo
**Pasos:**
1. Navegar entre los 4 tabs
2. En cada tab verificar que la barra de tabs es visible
3. Verificar el boton flotante "+" en el centro

**Resultado esperado:** La tab bar con el FAB es visible en todas las pantallas principales.

---

## Modulo 9: Flujos Combinados

### CP-054: Crear entrada con foto de camara y verificar en mapa
**Precondicion:** Usuario autenticado
**Pasos:**
1. Tocar "+" para nueva entrada
2. Tomar foto con camara
3. Llenar: titulo "Cafe en Roma", descripcion "El mejor espresso", ubicacion "Roma, Italia"
4. Seleccionar categoria "Gastronomia"
5. Guardar
6. Ir al tab Mapa
7. Buscar un nuevo pin en el area de Roma (no habra coordenadas porque se ingreso texto, pero verificar la entrada en el listado)

**Resultado esperado:** La entrada se crea, aparece en Inicio, y la experiencia es fluida entre tabs.

---

### CP-055: Flujo completo: login -> crear -> favorito -> buscar -> eliminar -> logout
**Precondicion:** App cerrada
**Pasos:**
1. Abrir app, autenticarse con PIN "1234"
2. Crear nueva entrada con titulo "Prueba E2E"
3. Ir a la entrada y marcarla como favorito
4. Buscar "Prueba E2E" en la barra de busqueda
5. Verificar que aparece en resultados
6. Activar "Solo favoritos" - verificar que aparece
7. Ir al detalle y eliminar la entrada
8. Verificar que ya no aparece en la lista
9. Ir a Perfil y cerrar sesion
10. Verificar que regresa a login

**Resultado esperado:** Todo el flujo se completa sin errores. Los datos son consistentes en cada paso.

---

### CP-056: Capturar QR, copiar, verificar en portapapeles
**Precondicion:** Usuario autenticado, codigo QR disponible
**Pasos:**
1. Ir a tab Capturar
2. Cambiar a modo "Escaner QR"
3. Escanear un QR
4. Guardar el resultado
5. Copiar el resultado desde la lista
6. Ir a Perfil > Portapapeles
7. Verificar el contenido copiado

**Resultado esperado:** El contenido del QR aparece correctamente en la seccion de portapapeles del perfil.

---

### CP-057: Modo oscuro afecta todas las pantallas
**Precondicion:** Usuario autenticado
**Pasos:**
1. Ir a Perfil y activar "Modo oscuro"
2. Navegar a tab Inicio - verificar tema oscuro
3. Navegar a tab Capturar - verificar tema oscuro
4. Navegar a tab Mapa - verificar tema oscuro
5. Abrir formulario de nueva entrada - verificar tema oscuro
6. Desactivar modo oscuro y repetir verificacion

**Resultado esperado:** El cambio de tema se aplica globalmente e inmediatamente en todas las pantallas y sheets.
