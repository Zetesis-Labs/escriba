# La biblioteca como actor asíncrono

Decidido por Rubén el 2026-10-12 y validado en pantalla el mismo día.
Sustituye la decisión de la fase B del plan de corrección
(`docs/plan-correccion-arquitectura.md`) de mantener `Store` síncrono. El
plan con su batería de tests está en `docs/plan-biblioteca-actor.md`.

## Contexto

Cada llamada a la biblioteca tomaba un `std::sync::Mutex<Store>` y esperaba,
bloqueando el hilo, a un hilo propio con su runtime que atendía SurrealDB de
una orden en una. El SDK ya era async: esa capa solo existía para volverlo
síncrono. Consecuencias: un pánico con el cerrojo tomado dejaba la biblioteca
inutilizada hasta reiniciar; ver una nota esperaba a que se guardara otra; y
cada espera ocupaba un hilo de tokio. Además, las garantías dependían de que
cada llamada tomara bien el cerrojo: los tres fallos corregidos en `1eed747`
venían de ahí.

## Decisión

Una tarea es la única dueña de `Store` y del `Surreal<Db>` de escritura.
`Library` es un manejador que se puede clonar y le envía órdenes de un `enum`
tipado. El `match` del actor es el único sitio que decide el orden y la
atomicidad. Invariantes, cada uno con su test en `library/tests.rs`:

1. Las escrituras se aplican de una en una, en el orden en que llegan.
2. Lees lo que escribes: el actor publica índice y trabajos activos antes de
   responder.
3. Un error vuelve a quien envió la orden. Un pánico se captura, vuelve como
   error, el actor recarga su índice de la base y sigue atendiendo.
4. Ningún hilo de tokio espera de forma bloqueante a la biblioteca.
5. `close()` atiende lo que ya está en cola antes de soltar la base. La app
   lo llama al salir.

Las lecturas que no necesitan al actor (detalle de una nota, instantánea,
contexto de recetas, memoria, registro, trazas, personas, trabajos) van
directas a un `Surreal<Db>` clonado, apoyadas en el índice publicado. El
registro de errores encola la línea al momento, sin esperar respuesta ni
republicar.

## Alternativas descartadas

- **`tokio::sync::Mutex<Store>`.** Deja de bloquear hilos, pero la garantía
  sigue dependiendo de que cada llamada tome el cerrojo, y leer sigue
  esperando a escribir. Fue el paso intermedio (`6a0eee9`).
- **Conservar el hilo de persistencia.** Es la pieza que bloquea.
- **Órdenes como cierres sobre `Store`.** La interfaz sería tan ancha como
  `Store`. Solo los tests usan un cierre (`with_store`).

## Alcance

Los trabajadores de carril (1 de inferencia y 3 de red, `run_lane` en
`lib.rs`) siguen siendo tareas, no actores. Lo que daría un actor ya existe:
cancelar retira el permiso de la receta, avisa al controlador de Bun, cierra
su proceso y, si es inferencia, corta también el proceso nativo; cada trabajo
tiene un límite de dos horas (`scripts.rs`). Solo añadiría relanzar un carril
cuya tarea muera por un pánico, que solo ocurre por un fallo de programación.
Se reconsidera si eso pasa a ser un problema real.

## Consecuencias

- `Store`, la cola y el catálogo son `async`, y sus tests usan
  `#[tokio::test]`. La app abre la biblioteca con `block_on` al arrancar y la
  cierra igual al salir, ambos en el hilo principal.
- Tests: la batería de nueve invariantes y `lifecycle_tests.rs` (salir sin
  colgarse ni perder lo encolado, e incorporar un audio vigilado una sola
  vez). Quedan sin test la descarga desde iCloud, las notificaciones, la barra
  de menús y los motores locales reales.
- Publicar clona el índice en cada escritura que no sea registro. No se nota
  en la suite; medir con la biblioteca real si la interfaz va lenta.
- Commits: `52b490e` (batería), `6a0eee9` (persistencia async), `c494f67`
  (actor), `7e6fa67` (tests de la app).
