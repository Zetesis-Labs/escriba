# Persistencia de Escriba

Escriba guarda la biblioteca en SurrealDB 3.3 embebida con RocksDB (ADR-0008), bajo `library.rocksdb` dentro de su carpeta de Application Support. El controlador Bun la abre antes de anunciar `ready`; la interfaz accede mediante el comando Tauri que Rust reenvía al controlador. Un `library.surrealkv` sin convertir impide abrir la biblioteca: esta versión ya no lo lee y no la sustituye por una vacía. Un bloqueo de instancia impide abrir la misma biblioteca dos veces. La base de conocimiento `knowledge.rocksdb` permanece separada en Rust. [SurrealDB documenta la conexión embebida y el bloqueo de la carpeta](https://surrealdb.com/docs/reference/rust/embedding).

Una copia de `knowledge.rocksdb` necesita su archivo hermano `knowledge.key`,
con permisos `0600`: contiene la credencial local con la que Rust autentica el
acceso a esa base. Copiar únicamente el directorio hace que se genere otra
clave y falle la autenticación. Las copias se preparan con la app cerrada y
conservan la base y la clave sin mostrar el contenido de esta última.

El adaptador de RocksDB entrega al motor Node la ruta física sin escaparla como
URL: `Application Support` y `Application%20Support` son directorios distintos.
La apertura conserva espacios, Unicode y porcentajes literales. Las rutas con
`?` se rechazan antes de abrir el motor porque este carácter introduce opciones
en el endpoint nativo. Las pruebas de reapertura copian una biblioteca cerrada
a rutas con estos caracteres y comprueban notas, versiones y personas.

## Esquema

La marca `meta:schema` vale `2`. Las tablas son `recording`, `version`, `publication`, `version_preview`, `publication_preview`, `account`, `resolver`, `recipe`, `destination`, `provider`, `log`, `setting`, `job`, `memory`, `trace`, `person`, `person_voice`, `voice`, `note_draft`, `note_draft_receipt` y la cola privada `audio_deletion`. Cada entidad tiene una fila, con `key`, `parent` cuando corresponde, `position` y `payload` como valor nativo de SurrealDB. `position` ordena versiones, recibos y catálogos; las grabaciones se ordenan por `createdAt` descendente y después por `key`, y su `position` se ignora. No existe un documento JSON global. Grabaciones, versiones y jobs exponen además campos consultables directamente: `title`, `status`, `createdAt`, `backend`, `state` y `recordingId`. Cada tabla tiene un índice único en `key`; versiones, recibos, jobs, memorias, trazas, huellas y borradores tienen índice en `parent`. [Los índices únicos y normales son parte del esquema SurrealQL](https://surrealdb.com/docs/reference/query-language/statements/define/indexes).

La caché en memoria de `Store` (`src/runtime/library/store.ts`) conserva solo el índice ligero de la biblioteca. Cada mutación edita una copia tipada y `src/runtime/library/changes.ts`, una función pura, calcula las filas que cambiaron comparando por identidad: incorporar una nota escribe esa fila y ninguna otra, y las versiones solo se comparan en la nota que la mutación declara. El escritor ejecuta esas operaciones y sus efectos asociados (proyecciones, borrados en cascada, huellas, borradores y alias de receta). Grabación, versiones y recibos, junto con las memorias, trazas y jobs eliminados al descartar y la petición de borrar su audio, se confirman en una sola transacción. Si falla una sentencia, la transacción se cancela y la caché permanece sin cambios. [SurrealDB describe las transacciones del SDK](https://surrealdb.com/docs/reference/rust/concepts/transaction).

El registro de la app vive en la tabla `log`, fuera del índice y de `library`/`snapshot`: cada línea es una fila con su propia transacción, se lee con `log_list` ordenada por `payload.at` y se recorta a las últimas 3000 al abrir y cada 64 líneas. Las líneas de bibliotecas anteriores se leen sin convertirlas. Registrar una línea no reescribe grabaciones ni emite `escriba://changed`; emite `escriba://log`.

Descartar deja una lápida con solo `id`, `source`, `sourceKey`, `legacyKey` y `status: discarded`; no conserva título, transcripciones, versiones, resúmenes, datos, recibos ni la ruta de la copia. La biblioteca visible omite esas lápidas y la vigilancia las usa para no reincorporar el origen. La cola `audio_deletion`, separada del registro y de las respuestas a la UI y recetas, conserva la ruta de la copia y su identidad de dispositivo e inodo. Tras confirmar la transacción y al abrir la biblioteca, el controlador comprueba que sigue siendo un archivo normal dentro de `audio`, con la misma identidad y sin referencias de otra grabación, antes de borrarlo y retirar la petición. Si el borrado falla, queda pendiente para otro arranque; el archivo de origen, las publicaciones externas y las huellas ya aprendidas por Personas permanecen intactos.

`Store.open` convierte automáticamente el `library.json` de la primera versión cuando aún no hay datos en SurrealDB. Ese fichero solo se lee y queda intacto. Si encuentra filas SurrealDB del esquema `1`, convierte sus cadenas JSON a objetos nativos en una transacción y actualiza la marca a `2`. Un error de esquema o del índice detiene la apertura con un error visible; no se arranca con una biblioteca vacía. El contenido completo de una versión se valida al construir su proyección inicial y al solicitar el detalle; los arranques siguientes no lo leen para validarlo de nuevo.

Al actualizar, `Store.open` retira una sola vez las asignaciones de receta guardadas en grabaciones anteriores, cuya procedencia no constaba. La elección explícita hecha al incorporar una nota nueva se conserva; sin ella, el runtime consulta la receta por defecto vigente al procesarla. Cada versión y traza mantienen la receta que se ejecutó.

Los trabajos conservan `automatic`, que distingue lo incorporado por el pipeline
de las acciones manuales incluso tras reintentos o reinicios. Un proceso
completado devuelve y conserva `versionId`; el aviso de transcripción usa esa
versión y solo se envía después de confirmar el trabajo. Un trabajo cancelado
no confirma el resultado ni emite el aviso.

Las capturas que quedaron pendientes de incorporar se recuperan con la fecha
de modificación de su archivo como `createdAt`, conservada al reabrir la
biblioteca. La recuperación no les asigna la fecha del reinicio.

## Modelo en memoria y trabajos

La caché usa `LibraryIndex`: metadatos de grabaciones y proyecciones de sus
versiones y publicaciones. Cada versión conserva hasta 400 caracteres de texto,
título, descripción breve, etiquetas, duración, idioma y una huella de revisión.
No carga segmentos, palabras, reconocimientos, resumen completo, datos de receta
ni programas y respuestas completas de publicación. Las extensiones arbitrarias
se conservan en el documento completo, no se duplican en la lista.

`version_preview` y `publication_preview` contienen filas pequeñas separadas
del contenido completo y se confirman con él en la misma transacción. La lista
no recorre las tablas de transcripciones ni de recibos completos. La marca `meta:preview_v1` indica que se han generado las
proyecciones de bibliotecas anteriores: se recorre cada fila por separado y la
marca solo se confirma tras validar el índice. El esquema sigue siendo `2`.

`recording_detail` consulta solo la grabación seleccionada y sus hijos mediante
el índice de `parent`, y contrasta sus identidades y orden con las proyecciones.
El runtime
hace lo mismo para la nota que está procesando. La WebView descarta el detalle al
cambiar de selección o salir de Biblioteca; un cambio de revisión vuelve a
cargarlo. `snapshot` conserva la lectura completa para solicitudes explícitas,
pero no interviene en el arranque ni en los refrescos de la lista.

Las mutaciones de versiones y recibos hidratan únicamente la grabación afectada.
La persistencia recibe ese ámbito de escritura y nunca guarda proyecciones sobre
transcripciones completas. Los cambios de ajustes, catálogo o metadatos no leen
las transcripciones. Los alias de receta se aplican en la base de datos de forma
simultánea, incluso en cadenas o intercambios de identificadores.

Los datos completos usan los esquemas Zod de `src/runtime/library/model.ts`, con
segmentos, palabras y reconocimientos tipados. Conservan campos opcionales
ausentes, nulos y extensiones; un campo conocido de tipo incorrecto falla antes
de confirmar el cambio. El JSON queda en IPC, datos abiertos de recetas y filas
de SurrealDB. Los módulos de `src/runtime/library/` separan grabaciones, versiones,
ajustes, catálogos, personas, importación, proyecciones y vistas; `persistence.ts`
separa la lectura del índice y detalle de las transacciones.

Las carpetas vigiladas también están tipadas. Su bookmark de macOS se conserva
como valor opaco y se valida al restaurar el acceso: una autorización antigua
dañada no impide abrir el resto de la biblioteca.

La cola usa `Job` con estado y operación enumerados. Reclamar, esperar y encolar leen solo los trabajos activos (índice en `state`), los de una nota (índice en `parent`) o uno por id; el historial completo solo se lee en `runtime_history`. La copia y el hash del audio al incorporar se hacen antes de tomar la biblioteca, que solo se bloquea para decidir y confirmar. Guarda `errorCode` junto al
texto; la decisión de reintento usa ese código, conservado al atravesar el
controlador y el worker de Bun. Los trabajos anteriores siguen siendo legibles
sin ese campo y conservan su estado de espera o recuperación.

## Proveedores y autorizaciones

La tabla `provider` conserva manifiestos y programas instalados. Las bibliotecas
anteriores abren con este catálogo vacío, sin cambiar IDs ni credenciales de
Notion/OKF. `account.grant` guarda la autorización explícita de proveedores
externos; el token permanece en su archivo privado. Instalar un proyecto nunca
crea una autorización. Los destinos `managed` pertenecen al formulario de la app
y conservan sus valores al reconstruir el proyecto. Retirar un proveedor lo marca
como no disponible sin borrar cuentas ni programas de publicaciones anteriores.

`recording.accountEffectPending` se confirma antes de una escritura de SDK y
permanece tras el éxito. La cola bloquea la recuperación o el reintento automático
de esa operación; sólo el inicio de un nuevo reprocesado manual retira la marca.
Esto cubre también un cierre entre el efecto externo y la confirmación del job.

## Conocimiento instalado

`escriba` es la ontología base integrada, visible aunque no haya proyecto ni
extensiones instaladas. El listado de su esquema no abre el motor de
conocimiento. Expone `person`, `recording`, `version`, `transcript`, `speaker` y
`segment`, con relaciones `has_version`, `has_transcript` e `identified_as`.
Solo se proyecta la versión vigente de cada nota, con la misma regla que la
interfaz: la marcada y, si no hay marca, la última. Elegir otra versión
sustituye su proyección; las anteriores siguen en la biblioteca, no en el
grafo. El segmento lleva sus palabras en `words` (`text`, `start`, `end`) y
referencias nativas `transcript` y `speakerRecord` con `REFERENCE`, que se
recorren al revés con `<~segment`. En SurrealDB cada relación escribe siete
claves con los ids de sus extremos; medido sobre una biblioteca de 199 notas, el
grafo pasó de 2,2 GB con palabras y relaciones sueltas a 423 MB con las palabras
en el segmento, a 146 MB con referencias en lugar de `has_segment` y
`spoken_by` y a 80 MB con solo la versión vigente. Personas y grabaciones
reutilizan los UUID de la biblioteca; los hijos usan IDs compuestos con la
grabación y versión. El índice de segmento sólo identifica contenido dentro de
esa versión.

La base vive en una base de datos con sufijo de formato (`_v2`). Al abrir un
grafo anterior, la base nueva se proyecta entera en segundo plano (7 s en
release para una biblioteca de 199 notas) y la antigua se elimina con
`REMOVE DATABASE`. Borrarla registro a registro, con sus aristas, tardaba casi
una hora de CPU. `REMOVE DATABASE` solo retira la definición: una tarea de
SurrealDB borra los datos pasados 10 minutos, clave a clave, y la compactación
de RocksDB, automática y al menos cada hora, devuelve el espacio. Con SurrealKV
no lo devolvía (ADR-0008). Una base antigua que fuera una extensión llamada
`escriba` no se toca.

La base es una proyección persistida de la biblioteca. Los eventos privados de
`recording`, `version` y `person` encolan el propietario afectado en
`knowledge_dirty`, con revisión única, dentro de la transacción original. Antes
de leer la base, el host consume esa cola de uno en uno: obtiene una persona o
una grabación con sus versiones, filtra los campos públicos, reemplaza su
proyección de forma atómica y retira únicamente la revisión consumida. El
bloqueo de sincronización abarca también la consulta que la necesita.
`knowledge_meta` conserva la marca de incorporación inicial y el identificador
de la proyección; recrear el grafo vuelve a encolar las identidades existentes
sin perder eliminaciones pendientes. Los borradores sin confirmar no se
proyectan. No se exportan rutas, credenciales, huellas, recibos ni los campos
abiertos `inputs`, `data` y extensiones de transcripción.

`api.grafo("escriba")` usa el mismo SDK y una dependencia implícita de v1. La
base rechaza escrituras explícitamente mediante validación del AST y permisos
de tabla de sólo lectura. No permite guardar, borrar ni vincular registros por
los formularios del grafo. El ID `escriba` está reservado; una extensión antigua
que lo use provoca un error visible, conservando su esquema y datos.

El grafo reside en `knowledge.rocksdb`, un almacén físico separado de
`library.rocksdb`, dentro de Application Support; un `knowledge.surrealkv`
sin convertir impide abrirlo, como en la biblioteca. Usa el espacio `knowledge`
y una base lógica distinta por ID estable de ontología. Un catálogo privado
localiza las bases; cada una conserva su definición instalada y las tablas de
registros, vínculos y correcciones manuales. Las ontologías candidatas del
proyecto actual se guardan en los ajustes de la biblioteca, pero construir o
cambiar de proyecto no instala, actualiza ni borra el grafo. Las definiciones
instaladas y sus registros sobreviven a ese cambio.

Una instalación exige versión entera positiva, migraciones consecutivas desde
la primera versión y un prefijo idéntico al ya aplicado. La misma versión no
puede redefinirse ni se puede volver a una anterior. Las migraciones pendientes,
el manifiesto instalado y las protecciones del host se confirman juntos; un
fallo revierte la actualización. Solo una instalación o actualización explícita
ejecuta migraciones, nunca la ejecución de una receta. Se permiten DDL de tablas,
campos, índices, funciones, analizadores, secuencias y parámetros, excepto el
espacio reservado `_escriba_`. Se excluyen `EVENT`, `TABLE AS SELECT` y acciones
`REFERENCE ON DELETE THEN` porque en SurrealDB 3.3.2 sus callbacks ejecutarían
trabajo con privilegios superiores a la receta.
La base desactiva acceso de red, scripting JavaScript y notificaciones `live`.

Rust abre las consultas de receta como sesión `RECORD` de la base concreta y
contrasta la dependencia `{id,minVersion,maxVersion}` almacenada en el catálogo
de recetas y la versión exacta abierta. Esa sesión puede operar sobre datos según
los permisos SurrealQL de las tablas, pero no definir esquema, cambiar de base
con `USE` ni administrar autenticación. El SDK SurrealDB 2.1.1 viaja por el RPC
del worker como CBOR en base64: conserva `RecordId`, fechas y decimales nativos.
Los formularios de Biblioteca intercambian JSON, con campos y relaciones
declarados en la definición instalada; no se convierten en el transporte del SDK.

Los registros pueden tener varios vínculos con grabaciones y versiones de nota.
Rust guarda la procedencia de cada vínculo, incluida la receta cuando lo creó
una ejecución. Desvincular una nota no elimina el registro compartido. Las
operaciones de vínculo aceptan solo registros de tablas declaradas en
`collections`; una consulta raw puede trabajar con otras tablas de la misma
ontología si sus permisos SurrealQL lo permiten. Las
ediciones manuales de la UI comparan la huella de revisión antes de guardar o
borrar; un conflicto conserva el estado anterior. Una protección instalada por
el host impide que una receta sobrescriba un registro corregido manualmente.
La lista de colecciones se pagina; no se incorpora al índice ligero de la
biblioteca. Los campos `reference` de las extensiones apuntan a una entidad de
la base mediante `{ontologyId, table, id}`. El formulario valida las referencias
nuevas y conserva las antiguas cuyo original se haya eliminado; no borra el
conocimiento extendido ni recrea personas. Son referencias explícitas, sin
recorridos SurrealQL entre bases de ontologías ni proyecciones vectoriales
gestionadas.

Toda `graph.query` de una extensión marca `recording.accountEffectPending` antes de enviarse,
porque el SQL raw puede escribir incluso cuando parezca una lectura. Así se
bloquea el reintento automático si no se conoce el resultado; `dryRun` deniega
el grafo. Las consultas de sólo lectura a `escriba` no activan ese marcador.
Un lote `BEGIN`/`COMMIT` de SurrealQL de una extensión puede ser transaccional, pero
el puente no ofrece transacciones interactivas del SDK ni consultas `live`.

## Borradores de notas

`note_draft` conserva un borrador por grabación, fuera del índice ligero, del
snapshot y del contexto de recetas. Se lee sólo mediante los comandos de detalle
`note_draft_get` y `note_draft_begin`. Sobrevive a cambiar de nota y al reinicio.
Si una biblioteca antigua no identifica una versión vigente válida, el borrador
usa la última por fecha, igual que la interfaz, sin modificar el original.
El contenido editable está tipado: título, transcripción, resumen opcional y
JSON de datos. Segmentos y palabras conservan las extensiones y los tiempos;
los intervalos negativos o invertidos se rechazan antes de guardar.

Guardar el borrador aumenta su revisión y no modifica versiones, grabación ni
publicaciones. Cada escritura exige el id del borrador y su revisión esperada.
Guardar y confirmar contrastan además la versión vigente y una huella del
contenido completo de la versión base y del título de la grabación. Los
conflictos se muestran como errores y conservan el borrador; descartarlo sigue
siendo posible aunque haya cambiado la base.

Confirmar copia la versión base, incluidos receta, entradas, esquema y otras
extensiones, y aplica todos los cambios en una sola versión manual. Conserva las
versiones originales y el audio. `version.title` fija el título de la nueva
versión y se incluye en su proyección; si hay resumen, también actualiza
`digest.title`. El título de la grabación cambia únicamente al confirmar. No se
regeneran ni envían publicaciones. Una confirmación sin cambios cierra el
borrador sin crear otra versión.

La versión, sus proyecciones, las huellas conservadas, el borrado del borrador y
un recibo mínimo en `note_draft_receipt` se confirman en una sola transacción.
El recibo contiene id de versión y revisión, sin texto: repetir una confirmación,
incluso después de reiniciar, no crea otra versión. Un fallo transaccional
conserva el borrador y el estado previo de la biblioteca. Descartar la grabación
elimina también sus borradores y recibos en la misma transacción que la lápida.

Las correcciones manuales no enseñan huellas a Personas. Se copian sólo las
huellas cuyos segmentos mantienen los intervalos y una correspondencia de
hablante inequívoca. Dividir, quitar o mezclar la asignación de un hablante
retira sólo las huellas afectadas; las de hablantes sin cambios se conservan en la
nueva versión. Las versiones originales y las huellas ya aprendidas permanecen.

## Personas y huellas privadas

`person` conserva los nombres; `person_voice`, las huellas aprendidas con su modelo, origen y fecha; `voice`, las huellas de cada versión de transcripción. El controlador Bun consulta estas tablas; sus vectores no forman parte del documento que recibe la WebView o una receta. La interfaz obtiene nombres y metadatos de las huellas, `hasVoices` en las versiones y reconocimientos `{speaker, person, distance}`. Las respuestas públicas rechazan cualquier campo de embedding.

`people_list` expone el UUID canónico de cada persona. Una selección manual o un
reconocimiento nuevo conserva ese `personId` en los segmentos y, en el segundo
caso, en el reconocimiento. La proyección sólo crea `identified_as` si existe
esa persona y todos los segmentos del hablante coinciden en su identidad. Los
nombres antiguos sin UUID no se interpretan como una asignación de identidad.
Cada segmento conserva además su `personId` explícito, aunque otras partes de
ese hablante no estén identificadas o tengan una asignación distinta.

El color opcional pertenece a la persona, no a una versión ni a un hablante de
una nota. `people_set_color` sólo acepta `#RRGGBB` y una persona existente; no
crea perfiles implícitos. Añadir huellas y renombrar conserva el color. Al
fusionar, prevalece el color del destino; si no tiene, hereda el del origen en
la misma transacción que las huellas. Olvidar la persona o su última huella
elimina también su color. Las entidades anteriores, sin color, siguen siendo
legibles, y `people_list` devuelve sólo este metadato y los ya públicos.

Al transcribir, el controlador separa las huellas del resultado nativo, reconoce por la huella más cercana del mismo modelo con umbral de distancia coseno 0,30 y conserva una asignación de persona por hablante, sin repetir persona en la nota. Las huellas quedan pendientes en Bun hasta guardar la versión. La versión y sus huellas se confirman juntas; las correcciones pueden enseñar la voz en esa misma transacción. `sourceVersionId` permite copiar las huellas al reutilizar una transcripción o corregir hablantes sin repetir reconocimiento. Una transcripción diarizada sin huellas se vuelve a diarizar.

«Registrar voz» usa `voice-samples` dentro de la carpeta privada de la app y no incorpora una nota. Exige al menos 30 segundos de habla del hablante dominante, guarda su huella y elimina la muestra al terminar o cancelar. Al arrancar se retiran las muestras de cierres interrumpidos. Quitar una persona no modifica los nombres de las notas; borrar una versión elimina sus huellas propias y conserva las ya aprendidas por personas.

Además del micrófono, se puede elegir un archivo de audio. Rust copia el archivo a `voice-samples`, extrae la huella con la misma validación y elimina esa copia al terminar o fallar. El archivo elegido permanece intacto y el audio no se publica ni se incorpora a la biblioteca.

## Archivos locales

La raíz de Application Support, RocksDB y las carpetas de audio y credenciales tienen permisos `0700`; las copias de audio, `0600`. Esto restringe el acceso de otros usuarios locales del equipo, sin cifrar la biblioteca.

Para carpetas vigiladas, `sourceKey` incluye la carpeta y la identidad estable del archivo. Una nota de voz renombrada conserva la misma grabación y versiones; si cambian sus bytes se guarda una nueva copia de audio y se marca pendiente. Una nota inicialmente vacía se puede recuperar por esa identidad aun después de renombrarse. La importación manual conserva su deduplicación por hash de contenido.

## Comprobaciones

`tests/runtime/library/` ejercita datos sintéticos sobre RocksDB: reinicio, versiones, recibos, ajustes, jobs, memorias, trazas, conversión del esquema anterior, rollback ante una restricción real de SurrealDB, borrado transaccional, identidad estable de una nota de voz renombrada y recuperación tras matar el proceso inmediatamente después de un commit. No usa bibliotecas ni credenciales reales. Las pruebas Rust cubren el puente de conocimiento y las capacidades de cáscara.

## Proyección incremental de la base

La base `escriba` se proyecta por unidades: la fila de la grabación y cada
versión con su transcripción, segmentos, hablantes, palabras y aristas. Cada
unidad guarda una huella de su contenido en `_escriba_projection` (sin
permisos para recetas). Al sincronizar una grabación solo se reescriben las
unidades cuya huella cambió: editar el título no toca versiones y corregir una
versión no reescribe las demás. Una grabación proyectada por una versión
anterior, sin huellas, se rehace entera una vez.

La sincronización corre en segundo plano en tramos de medio segundo y se
despierta con cada cambio de la biblioteca. Filtros y mapas esperan como
máximo dos segundos; las consultas de recetas a la base y los formularios de
registros sincronizan del todo. La conexión raíz del grafo no tiene un cerrojo
global: cada operación clona su sesión y solo las instalaciones de ontologías
se serializan. Las consultas SurrealQL de los filtros se ejecutan dentro de una
transacción que siempre se descarta, además de pasar el validador de lectura.
