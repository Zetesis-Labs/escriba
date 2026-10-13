# El dominio en Bun y Rust como cáscara

Dirección decidida por Rubén el 2026-10-13. No es un encargo de
implementación: fija hacia dónde se mueve la arquitectura y qué hace falta
comprobar antes de planificarla. Corrige una premisa del ADR-0003 y no toca el
ADR-0010 (Linux), que sigue adelante.

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

1. **El dominio vive en un único proceso Bun de larga vida**, supervisado por
   Rust: biblioteca y versiones, conocimiento, cola de trabajos y recuperación,
   configuración, conectores, HTTP remoto y credenciales, orquestación de
   recetas. Es el controlador actual (`escriba-runtime`) con más
   responsabilidades, no otro ejecutable.
2. **Rust queda como cáscara**: ventana, menús, bandeja, notificaciones,
   permisos del sistema (carpetas, micrófono), arranque y supervisión de
   procesos (el controlador, las recetas, los hosts nativos), aislamiento, y la
   captura e inferencia que exigen APIs del sistema. Rust no abre la base de
   datos.
3. **Las recetas siguen aisladas en procesos aparte** sin credenciales, rutas
   de audio ni huellas. El límite de seguridad del producto es ese proceso, no
   el lenguaje.
4. **La costura se estrecha**: la WebView habla con el controlador a través de
   Rust solo para lo que Rust aporta; el resto del contrato pasa a ser
   TypeScript con TypeScript, sin tipos generados.
5. **El ADR-0010 no cambia.** Los hosts nativos en Rust (Linux y, en el Mac,
   grabación y materialización) son cáscara según esta decisión. El plan de
   Linux (`docs/plan-linux.md`) vale con las dos arquitecturas y va antes.

## Alternativas descartadas

- **Dejar los dos dominios y anotar deuda.** Cada regla nueva obliga a decidir
  en qué lenguaje va y a cruzar la costura; no converge.
- **Mover solo lo que nació de la premisa falsa** (HTTP remoto con secreto).
  Son 650 líneas; no resuelve la doble capa.
- **Todo el dominio en Rust**, retirando el controlador TypeScript. Las recetas
  y los conectores son TypeScript por decisión de producto (ADR-0001); habría
  que duplicar el modelo de nota, versión y conector hacia ellas.

## Consecuencias

- Es una migración de unas 20.000 líneas de Rust a TypeScript, por verticales
  y con sus pruebas por delante. Se planifica en otro encargo; hasta entonces,
  lo nuevo que toque datos se escribe donde ya esté su vecino, sin abrir un
  tercer sitio.
- El controlador necesita salir de su aislamiento actual para leer los
  ficheros 0600 de credenciales, abrir la base de datos y salir a la red. El
  perfil de aislamiento de `runtime-host/sandbox.sb` se queda para las
  recetas; el controlador recibe un perfil propio o ninguno.
- Las garantías que hoy da Rust se trasladan: cola duradera que sobrevive al
  cierre de la ventana (el proceso Bun vive lo que la app), transacciones en
  SurrealDB, recuperación tras caída, y confirmación de recibo antes de
  efectos externos.
- Las huellas de voz pasan a guardarlas el controlador en la misma base. La
  regla del `CLAUDE.md` («ni recetas, conectores ni exportaciones reciben
  vectores») no cambia; «permanecen en Rust» pasa a «permanecen en el
  controlador y en el equipo».
- La importación de bibliotecas Swift (`store/import.rs`) se mueve también o
  se retira si ya no hay bibliotecas que importar.
- Comprobaciones pendientes antes de planificar: Bun 1.4.2 (el fijado en el
  repo) con `@surrealdb/node`; abrir una `library.rocksdb` existente creada
  por el crate 3.3.2 de Rust con el motor 3.3.4 y confirmar que Rust puede
  dejar de abrirla; medir el coste de arranque del binding de 40 MB; y qué
  pasa con `knowledge.surrealkv` (ADR-0007) en el mismo proceso.
- `apps/tauri/CONTRACT.md`, `runtime-host/README.md` y `CLAUDE.md` describen el
  reparto actual y siguen siendo ciertos hasta que la migración los cambie.
  La frase del `CLAUDE.md` «Tokens, rutas de audio y huellas no cruzan a
  código de recetas» es la regla correcta y se mantiene.
