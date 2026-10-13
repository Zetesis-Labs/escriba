# El dominio en Bun y Rust como cáscara

Decisión de Rubén del 2026-10-13, implementada por etapas en la rama
`feat/dominio-bun`. Corrige una premisa del ADR-0003. El ADR-0010 (Linux)
conserva su decisión de host nativo en Rust. La descripción de la arquitectura
anterior en «Contexto» es histórica; «Decisión» describe el reparto vigente
en el código. La release se construyó, firmó e instaló el 2026-10-14 tras
comprobar su arranque con una copia aislada. La validación manual de Rubén
sigue pendiente.

## Contexto

El ADR-0003 repartió la aplicación en «TypeScript implementa interfaz, recetas,
conectores y transformaciones; Rust custodia capacidades, archivos y
credenciales». Esa frase arrastra una premisa de la etapa Swift, cuando
TypeScript era solo el código de la receta: que las credenciales no podían
llegar a TypeScript. La regla real del producto es más estrecha: tokens, rutas
de audio y huellas no llegan al **proceso de la receta**. El controlador y los
conectores son código propio y pueden tener la clave.

Medido el 2026-10-13 sobre `apps/tauri/src-tauri/src` (33.500 líneas, tests
incluidos):

| Bloque | Líneas | Por qué está en Rust |
| --- | --- | --- |
| Biblioteca, persistencia, SurrealDB | 11.800 | la base de datos está embebida en Rust |
| Conocimiento: ontologías, filtros, grafo | 7.300 | consulta la misma base |
| Cola de trabajos y recuperación | 2.200 | ídem, y sobrevivir al cierre de la ventana |
| Procesos, proyecto de recetas, aislamiento | 4.600 | supervisar y aislar procesos |
| Nativo del Mac: grabadora, voces, carpetas, bandeja | 3.300 | APIs del sistema |
| Comandos y puente con la WebView | 2.400 | la costura entre los dos mundos |
| HTTP remoto con secreto | 350 | la premisa de las credenciales |

La premisa falsa explica 650 líneas. Lo que llenó Rust fue que la base de datos
vive embebida en el proceso de Tauri: todo lo que toca datos tuvo que ser Rust.
El resultado son **dos capas de dominio**, una en Rust (versiones, filtros,
grafo, estados de la cola) y otra en TypeScript (recetas, conectores,
resúmenes), unidas por 2.400 líneas de comandos y tipos generados. Esa doble
capa es lo que se quiere retirar.

El spike `spikes/surreal-bun/` comprobó el 2026-10-13 la condición necesaria:
un proceso Bun abre SurrealDB embebida (`@surrealdb/node`, motor 3.3.4, con
RocksDB y SurrealKV) con el mismo SDK que ya usan las recetas, escribe, aborta
transacciones y reabre la base, también compilado con `bun build --compile`.
El binding N-API de 40 MB va como recurso junto al ejecutable; hay versiones
para macOS y Linux en x64 y arm64.

## Decisión

1. **El dominio de la biblioteca vive en un único proceso Bun de larga vida**, supervisado por
   Rust: biblioteca y versiones, personas y huellas, cola de trabajos y recuperación,
   configuración, conectores, HTTP remoto y credenciales, orquestación de
   recetas. Es el controlador actual (`escriba-runtime`) con más
   responsabilidades, no otro ejecutable.
2. **Rust queda como cáscara**: ventana, menús, bandeja, notificaciones,
   permisos del sistema (carpetas, micrófono), arranque y supervisión de
   procesos (el controlador, las recetas, los hosts nativos), aislamiento, y la
   captura e inferencia que exigen APIs del sistema. Rust no abre la
   biblioteca. **Excepción justificada (comprobada el 2026-10-13):** el
   conocimiento (`knowledge.rocksdb`) sigue en Rust, porque validar que el
   SurrealQL de una receta es de solo lectura y filtrar sus migraciones exige
   el parser (`surrealdb-expr`), y porque el motor embebido de Node no tiene
   opción de autenticación: con una sesión `RECORD` rellena `$auth` pero no
   aplica los `PERMISSIONS` de tabla, así que la garantía de que una receta
   solo escribe donde su ontología lo permite solo existe en Rust. Es otro
   directorio RocksDB; lo que necesita de la biblioteca lo pide al
   controlador.
3. **Las recetas siguen aisladas en procesos aparte** sin credenciales, rutas
   de audio ni huellas. El límite de seguridad del producto es ese proceso, no
   el lenguaje.
4. **La costura se estrecha**: la WebView usa un solo comando Tauri; Rust reenvía
   los comandos de biblioteca al controlador y ejecuta los de cáscara y
   conocimiento. Los tipos generados quedan para los comandos que Rust atiende.
5. **El ADR-0010 no cambia.** Los hosts nativos en Rust (Linux y, en el Mac,
   grabación y materialización) son cáscara según esta decisión. La decisión
   de Linux está en [ADR-0010](0010-linux-host-nativo-en-rust.md).

## Alternativas descartadas

- **Dejar los dos dominios y anotar deuda.** Cada regla nueva obliga a decidir
  en qué lenguaje va y a cruzar la costura; no converge.
- **Mover solo lo que nació de la premisa falsa** (HTTP remoto con secreto).
  Son 650 líneas; no resuelve la doble capa.
- **Todo el dominio en Rust**, retirando el controlador TypeScript. Las recetas
  y los conectores son TypeScript por decisión de producto (ADR-0001); habría
  que duplicar el modelo de nota, versión y conector hacia ellas.

## Consecuencias

- La migración se hizo por verticales con pruebas de biblioteca, cola,
  credenciales, transporte y protocolo. El controlador abre `library.rocksdb`
  antes de anunciar `ready`; Rust no abre ese directorio.
- El controlador arranca sin `sandbox-exec` para leer los ficheros 0600 de
  credenciales, abrir la base de datos y salir a la red. El perfil de
  `runtime-host/sandbox.sb` sigue aislando cada receta.
- Las garantías antes implementadas en Rust permanecen: cola duradera que sobrevive al
  cierre de la ventana (el proceso Bun vive lo que la app), transacciones en
  SurrealDB, recuperación tras caída, y confirmación de recibo antes de
  efectos externos.
- Las huellas de voz las guarda el controlador en la misma base. La
  regla del `CLAUDE.md` («ni recetas, conectores ni exportaciones reciben
  vectores») no cambia; «permanecen en Rust» pasa a «permanecen en el
  controlador y en el equipo».
- La compatibilidad de la biblioteca existente se comprobó con una copia real
  y datos sintéticos; el conocimiento conserva su propia base en Rust.
- La regla del `CLAUDE.md` «Tokens, rutas de audio y huellas no cruzan a
  código de recetas» se mantiene. La validación en la app instalada sigue
  pendiente y no se deduce de las pruebas de código.
