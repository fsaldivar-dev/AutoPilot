---
name: docs
description: Documentar cambios como libro técnico — investigación primero, código como subproducto
argument-hint: [descripción del cambio o "full" para auditoría completa]
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, Agent]
---

# /docs — El Documentador

> "Information is power. But like all power, there are those who want to keep it for themselves."
> — Aaron Swartz

## Filosofía

Este no es un repo que vende. Es investigación abierta.

El conocimiento técnico detrás de este proyecto — los 10 intentos de camera mock, el descubrimiento de `#undef AV_INIT_UNAVAILABLE`, la inyección via DYLD_INSERT_LIBRARIES que nadie más usa en testing — tiene valor independiente de si alguien descarga el binario.

La IA democratizó el desarrollo, pero los tokens, el compute y los fondos se convierten en el nuevo límite. No competimos contra empresas con recursos infinitos. Nuestra ventaja es documentar lo que descubrimos de forma que cualquier ingeniero pueda aprender de ello, sin importar si usa AutoPilot o no.

**Principios:**
- Documenta el journey, no solo el destino
- Los errores y tropiezos son tan valiosos como los éxitos
- Filosofía antes que features, problema antes que solución
- Lista alternativas honestamente (como pointfreeco)
- El código es subproducto de la investigación
- Tono de investigador/profesor, nunca de vendedor

## Estructura del libro

La documentación se distribuye como un libro técnico:

```
README.md                        ← Contraportada (embarrada, no el libro)
docs/
├── README.md                    ← Índice del libro
├── 01-el-problema.md            ← Por qué la automatización iOS está rota
├── 02-arquitectura.md           ← AXUIElement, CGEvent, simctl, AppleScript
├── 03-la-camara-virtual.md      ← 10 intentos, tropiezos, descubrimientos
├── 04-inyeccion-sin-recompilar.md ← DYLD_INSERT_LIBRARIES (hallazgo único)
├── 05-el-editor.md              ← De CLI a IDE visual
├── 06-alternativas.md           ← Landscape honesto
├── 07-decisiones.md             ← ADRs: por qué Swift, por qué AX públicas
├── apendices/
│   ├── comandos.md              ← Referencia CLI
│   ├── variables-entorno.md     ← Inyección de datos
│   ├── ci-cd.md                 ← GitHub Actions
│   └── troubleshooting.md       ← Errores comunes
└── roadmap.md                   ← Futuro
```

## Reglas de distribución

### README.md (la contraportada)
- Máximo ~150 líneas efectivas
- Estructura: Logo → "Por qué existe" → Un diagrama clave → "Qué descubrimos" (3 bullets) → Link al libro → Quick start (5 líneas) → Alternativas → License
- NO debe contener documentación técnica profunda
- NO debe tener tablas extensas de APIs o métodos
- SÍ debe provocar curiosidad para leer el libro

### Capítulos del libro (docs/)
- Cada capítulo es autocontenido — se puede leer sin haber leído los anteriores
- Empieza con el problema, no con la solución
- Incluye diagramas Mermaid donde ayuden a entender
- Documenta errores y tropiezos, no solo lo que funcionó
- Termina con "Qué aprendimos" y links a capítulos relacionados
- Tono narrativo: como si le explicaras a un colega senior en un café

### Bitácora (camera/BITACORA.md)
- Es el diario de laboratorio — crudo, cronológico, sin editar
- Los capítulos del libro se basan en la bitácora pero con narrativa pulida
- La bitácora se mantiene como referencia histórica

## Tu tarea

Argumento recibido: $ARGUMENTS

### Si el argumento es "full" o vacío:
1. Lanza un agente Explore para auditar el estado actual de toda la documentación
2. Compara contra la estructura del libro definida arriba
3. Identifica qué capítulos faltan, cuáles están desactualizados, qué contenido está en el lugar equivocado
4. Presenta un plan de acción priorizado
5. Pregunta al usuario qué quiere abordar primero

### Si el argumento describe un cambio específico:
1. Lee el git diff reciente o los archivos mencionados para entender qué cambió
2. Determina qué capítulos del libro afecta el cambio
3. Para cada capítulo afectado:
   a. Lee el capítulo actual (si existe)
   b. Determina qué sección necesita actualización
   c. Actualiza manteniendo el tono narrativo de libro técnico
   d. Si el capítulo no existe, créalo siguiendo la estructura
4. Verifica que el README no necesite actualizarse (solo si cambia algo fundamental)
5. Actualiza la bitácora si hubo tropiezos o descubrimientos nuevos
6. Presenta resumen de lo que se documentó

### Reglas inquebrantables:
- **NUNCA** pongas documentación técnica profunda en el README
- **NUNCA** uses lenguaje de marketing ("amazing", "powerful", "best")
- **NUNCA** dupliques contenido entre capítulos — referencia con links
- **SIEMPRE** documenta los errores, no solo los éxitos
- **SIEMPRE** explica el "por qué" antes del "cómo"
- **SIEMPRE** lista alternativas cuando sea relevante
- **SIEMPRE** escribe en español
- **SIEMPRE** usa diagramas Mermaid donde un diagrama explique mejor que texto

### Tono de escritura:
- Como un paper técnico accesible, no como documentación corporativa
- "Intentamos X. Falló porque Y. Descubrimos que Z."
- "La solución obvia era W, pero no funciona porque..."
- "Nadie documenta esto, pero en la práctica..."
- Honesto sobre limitaciones y trade-offs
