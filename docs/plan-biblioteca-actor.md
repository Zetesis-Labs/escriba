# Plan: la biblioteca como actor asíncrono

Revisión del 2026-10-12 sobre `feat/filtros-biblioteca` (`1eed747`). Encargo
de Rubén: llevar la biblioteca al patrón async correcto, con la batería de
tests definida antes de tocar código. Este documento es ese plan; «Estado»
recoge lo hecho en cada paso.

## Diagnóstico

Hoy una llamada a la biblioteca atraviesa tres capas:

1. Un handler async de Tauri toma `std::sync::Mutex<Store>`
   (`lib.rs:54`, `Runtime::store`).
2. `Store` llama a `Persistence::request`, que bloquea el hilo en un
   `std::sync::mpsc::Receiver::recv` (`persistence.rs:357`).
3. Un hilo propio con un runtime `current_thread` atiende las órdenes de una
   en una (`persistence.rs:183-205`) y llama al SDK de SurrealDB.

Bloquear un hilo de tokio en código async es un antipatrón, y el SDK ya es
async: la capa 3 existe para volver síncrono algo que no lo es. Efectos que
se pueden observar:

- **Un pánico con el cerrojo tomado lo envenena.** Desde ese momento cada
  llamada devuelve «No se pudo acceder a la biblioteca» hasta reiniciar.
- **Las lecturas esperan detrás de los commits.** Mostrar el detalle de una
  nota espera a que termine de guardarse otra, porque las dos pasan por el
  mismo cerrojo y por el mismo hilo.
- **Cada espera ocupa un hilo de tokio.** Con varias esperas a la vez se
  queda sin hilos para el resto: red, grafo, temporizadores.

La fase B lo dejó así a propósito porque, con SurrealKV, la espera dominante
era el commit (~30 ms) y cambiar el cerrojo por uno de tokio no la acortaba.
Era cierto, pero no era la pregunta: el problema es el patrón, no la latencia.

El grafo ya sigue el patrón correcto: `Knowledge` usa el SDK directamente en
el runtime de la app, sin hilo ni cerrojo global. La biblioteca debe quedar
igual.

## Estructura objetivo

Un **actor**: una tarea en el runtime de la app es la única dueña del estado
de la biblioteca (`LibraryIndex`, borradores de voces pendientes) y del
`Surreal<Db>`. Los demás le hablan a través de un módulo `Library`, un
manejador que se puede clonar.

- **Desaparecen** el hilo de persistencia, su runtime privado, el
  `enum Command` de 66 usos y el canal síncrono. Las funciones de
  `persistence/` pasan a ser `async fn` sobre `&Surreal<Db>` que el actor
  llama directamente. Conservar el hilo dejaría el patrón a medias: es la
  pieza que bloquea.
- **Desaparece** `Arc<Mutex<Store>>`. Las escrituras van en serie porque hay
  un solo dueño, no por un cerrojo: la garantía queda en la estructura y no en
  la disciplina de cada llamada. Es la garantía que faltó en los tres fallos
  de `1eed747`.
- El núcleo funcional no cambia: `persistence/changes.rs` sigue calculando,
  como función pura, qué filas cambian. El actor es la cáscara que ejecuta.

### Interfaz de `Library`

Pequeña, y con sus invariantes como parte de la interfaz:

| Operación | Cómo se atiende |
|---|---|
| `mutate(orden)` | Mensaje al actor; responde después del commit |
| `index()` | Instantánea publicada, sin pasar por el actor |
| `recording(id)`, audio, borradores | Lectura directa sobre un `Surreal<Db>` clonado |
| `claim`, `finish`, `cancel`, `enqueue` de trabajos | Mensajes al actor |

**Forma de los mensajes: un `enum` tipado**, no un cierre
`run(|store| …)`. Un cierre expone a cada llamada toda la superficie de
`Store`, y la interfaz sería tan ancha como la implementación. Con el `enum`,
el `match` del actor es el único sitio donde se deciden el orden y la
atomicidad. Las variantes reutilizan los tipos de `command.rs`, que ya están
deserializados a un `enum` (`0787e03`). Tipar más los parámetros que hoy van
como `Untyped` es otro encargo.

**Invariantes:**

1. Las escrituras se aplican en el orden en que llegan al actor, una cada vez.
2. Lees lo que escribes: cuando `mutate(...).await` devuelve, `index()` y
   `recording(id)` ya reflejan ese cambio. El actor publica la instantánea
   después del commit y antes de responder.
3. Un `Err` en una orden se devuelve a quien la envió; el actor sigue
   atendiendo. Un pánico dentro de una orden se convierte en `Err` para esa
   orden (`catch_unwind`) y no detiene el actor. Esto sustituye al cerrojo
   envenenado.
4. Ningún hilo de tokio espera de forma bloqueante a la biblioteca.
5. Al cerrar, el actor termina la orden en curso y las encoladas antes de
   soltar la base. Es lo que hace hoy `Drop for Persistence` al vaciar su
   canal; se conserva.

### Lecturas

`index()` devuelve la última `Arc<LibraryIndex>` publicada en un
`tokio::sync::watch`: la interfaz, el filtro y la cola la leen sin esperar al
actor. El detalle de una nota y el audio se leen con un `Surreal<Db>`
clonado, en paralelo con las escrituras, porque SurrealDB aísla cada
transacción. Entre la instantánea y el detalle puede haber milisegundos de
desfase para quien no escribió; para quien escribió se cumple el invariante 2.

### Cola de trabajos

Hoy `claim`, `finish`, `cancel` y `automatic` son atómicos porque se ejecutan
con el cerrojo tomado (22 usos en `jobs.rs`). En el actor, **cada una es un
mensaje**: el actor lee, decide y escribe sin que nadie se intercale. Las
decisiones puras (`next_in_lane`, carriles, capacidad) siguen en `jobs.rs`
como funciones sin I/O. Las esperas (`wake`, `wait`) siguen fuera del actor y
se alimentan de un aviso que el actor emite al cambiar un trabajo.

### Bordes síncronos

| Sitio | Puente |
|---|---|
| `run` (arranque), `restore_watched_folders` | `block_on` en el hilo de arranque, que no es de tokio |
| `start_watcher`, `start_project_watcher` | El callback de `notify` corre en un hilo ajeno: envía el evento a un canal y lo atiende una tarea |
| `scripts::store_host` (capacidad de recetas) | Ya es un futuro: `await` sobre `Library` |
| `job_notification`, `log_error`, `resolver_draft`, `project_path`, `folders`, `snapshot`, `library` (`lib.rs`) | Pasan a `async` o leen `index()` |
| `knowledge_commands::library` | Lee `index()` |
| `recorder.rs`, `voice_registration.rs` | Ya son `async`: `await` sobre `Library` |

Regla: `block_on` solo en hilos que no son de tokio; en cualquier otro sitio,
una tarea.

## Tests antes de implementar

Todos se escriben contra la interfaz de `Library`, en `library/tests.rs`. Para
detener una escritura usan un punto de control por instancia, solo de tests:
`stop_next_write()` la para con la biblioteca ocupada hasta soltar el
manejador, y `panic_next_write()` provoca un pánico en ese punto. En la
fachada el punto está dentro del cerrojo; en el actor irá entre calcular y
confirmar. «Hoy» indica cómo salen sobre la fachada del paso 1. Los rojos
llevan `#[ignore]` hasta el paso 3 para que la suite siga en verde.

| Test | Montaje y comprobación | Hoy |
|---|---|---|
| `las_escrituras_no_se_solapan` | 20 `version_save` en paralelo sobre una nota y 20 retitulados sobre otras cinco; están las 20 versiones y el índice publicado coincide con la base al reabrir | verde |
| `leer_no_espera_a_un_commit` | Con una escritura parada, `index()` y `recording(id)` de otra nota responden en menos de 100 ms | rojo, ignorado: `index()` ya cumple; el detalle espera al cerrojo |
| `ningun_hilo_de_tokio_se_bloquea` | Runtime `current_thread` (un solo hilo); con una escritura parada y una lectura esperando detrás, un `sleep` de 10 ms y una consulta al grafo terminan. Un vigía en otro hilo lo da por fallido a los 20 s | verde: la fachada lleva la espera al pool de `spawn_blocking`. Con la lectura síncrona falla; comprobado. Impide que el actor vuelva a bloquear |
| `lees_lo_que_escribes_y_en_orden` | 50 retitulados encadenados sobre una nota mientras otras tres se retitulan sin parar; tras cada `await`, `index()` y `recording(id)` muestran ese título | verde |
| `un_error_no_inutiliza_la_biblioteca` | Una orden sobre una nota que no existe y otra que entra en pánico devuelven `Err`; la siguiente funciona | rojo, ignorado: el pánico envenena el cerrojo |
| `la_cola_no_entrega_un_trabajo_dos_veces` | 30 notas y 45 trabajos: seis reclamadores en los dos carriles, y cada transcripción terminada encola su publicación. Ningún id se entrega dos veces y nunca corren dos de la misma nota | verde |
| `cancelar_y_terminar_a_la_vez` | 20 veces, `finish` y `cancel` simultáneos sobre un trabajo en curso: o termina y avisa, o queda cancelado; nunca las dos cosas ni ninguna, y el estado guardado coincide | verde |
| `cerrar_confirma_lo_encolado` | 20 líneas de registro lanzadas sin esperar y se suelta el manejador; al reabrir están las 20 | verde |
| `un_evento_de_carpeta_no_bloquea_al_vigilante` | Con una escritura parada, crear un archivo en una carpeta vigilada despierta al vigilante | verde; el plan lo daba por rojo, ver «Estado» |

Los verdes de hoy son las garantías que da el cerrojo; están para que el
actor no las pierda. Los rojos son lo que el actor aporta.

## Orden

1. **Fachada.** Crear `Library` con su interfaz async sobre el
   `Mutex<Store>` actual (`spawn_blocking` por dentro) y mover a ella todas
   las llamadas: 53 en `lib.rs`, 22 en `jobs.rs`, 4 en `scripts.rs`, 3 en
   `recorder.rs`, 2 en `knowledge_commands.rs` y 2 en `voice_registration.rs`.
   Sin cambio de comportamiento; los 319 tests siguen en verde.
2. **Batería.** Escribir la tabla contra `Library`. Salen los rojos
   previstos; si sale otro, se entiende antes de seguir.
3. **Actor.** Sustituir el interior de la fachada: actor, instantánea, lectura
   directa, cola como mensajes, borrar el hilo de persistencia y pasar los
   métodos de `Store` a `async`. Añadir `close()` y llamarlo al salir de la
   app, con su test. Convertir a `#[tokio::test]` los tests que
   usan `Store` directamente: 82 en `store/tests.rs`, 15 en `jobs.rs`, 9 en
   `catalog.rs`, 4 en `store/knowledge.rs` y 3 en `store/measurement.rs`.
   Quitar los `#[ignore]` de la batería, que pasa a verde.
4. **Bordes.** Vigilantes, arranque y capacidad de recetas según la tabla de
   bordes.
5. **Cierre.** ADR-0009 con la decisión, nota en el plan de corrección,
   instalación y validación en pantalla por Rubén: procesar, publicar
   mientras transcribe, editar títulos y vigilar una carpeta.

Tamaño: el paso 3 es el grueso (`persistence.rs` tiene 1.547 líneas y el
hilo con su `enum` es buena parte; `store/tests.rs`, 2.843). Calculo de
cuatro a seis sesiones de trabajo; el paso 1 se puede validar e instalar por
separado.

## Estado

- **Paso 1, fachada** (2026-10-12). `library.rs` define `Library`. Lo que está
  en memoria (`item`, `audio`, credenciales, vista ligera, ajustes, marcadores
  de carpetas) se lee de `index()`, una `IndexView` publicada en un `watch`
  después de cada escritura. La base y las escrituras se atienden con
  métodos async tipados que, de momento, toman el `Mutex<Store>` dentro de
  `spawn_blocking`. `Runtime::store()` ya no existe y el cerrojo solo vive
  dentro de `Library`. Siguen pasando los 319 tests.
  Decisiones tomadas por el camino:
  - **`Library` publica también los trabajos activos**, no la cola, porque
    descartar una nota borra sus trabajos a través de `mutate`. El menú y el
    evento `escriba://jobs` los leen de ahí. El menú ya no consulta la base
    desde el hilo principal con `try_lock`.
  - **Las operaciones de la cola** (`claim`, `finish`, `cancel`, `enqueue`,
    `automatic`, `stages`, `recover`) son funciones de `jobs.rs` sobre
    `&mut Store`, que `Library` ejecuta de una vez. `Queue` conserva los avisos
    y las esperas.
  - **Quitar el audio** comprueba los trabajos y escribe en la misma
    operación. Antes eran dos tomas del cerrojo.
  - **Grabar** importa la captura y fija su duración en una sola operación.
  - **`log_error` guarda el registro en una tarea aparte**, sin bloquear a quien
    lo llama.
  - **Las etapas que avisa el runtime** pasan por un canal y una tarea que las
    aplica en orden.
  - **Los tests** usan `Library::lock()`, que solo existe en tests, tiene la
    misma forma que el cerrojo anterior y publica al soltarse. El paso 3 lo
    retira al pasar los tests a async. Los de la cola ya son
    `#[tokio::test]`.
  Pendiente de medir o cubrir en el paso 3:
  - Publicar clona el índice en cada escritura, incluidas las líneas de
    registro. Con la batería no se nota (35 s, igual que antes); se medirá con
    el actor y, si pesa, se compartirán partes del índice con `Arc`.
  - Al salir, una línea de registro que aún esté en su tarea puede perderse.
    `cerrar_confirma_lo_encolado` no lo cubre (ver paso 2).
- **Paso 2, batería** (2026-10-12). `library/tests.rs` con los nueve tests de
  la tabla: siete verdes y los dos rojos previstos, que se ejecutaron con
  `--ignored` y fallan por la causa prevista (el detalle espera al cerrojo;
  tras el pánico la biblioteca responde «No se pudo acceder a la
  biblioteca»). Suite: 326 verdes y 9 ignorados.
  Lo que no salió como preveía el plan:
  - **El vigilante ya cumplía.** Los dos callbacks de `notify`
    (`watcher.rs` y `project_watch.rs`) solo envían a un canal, y la
    biblioteca la atiende una tarea: es el puente que pedía la tabla de
    bordes. El test queda como guarda para que el callback no llegue a la
    biblioteca.
  - **Cerrar aún no existe.** La fachada no tiene `close()`, así que el test
    suelta el manejador: comprueba que nada de lo lanzado se pierde mientras
    el runtime sigue vivo. No cubre la salida del proceso, donde el runtime
    se cancela con tareas sin empezar; eso exige `close()` en el paso 3.
  - **La cola admite un solo trabajo activo por nota**, que ya impone
    `enqueue`. Para ejercer «nunca dos de la misma nota» entre carriles, el
    test encadena publicación tras transcripción sobre la misma nota.
