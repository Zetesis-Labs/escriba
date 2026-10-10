# Persistencia de Escriba

Escriba guarda la biblioteca en SurrealDB 3.3 embebida con SurrealKV, bajo `library.surrealkv` dentro de su carpeta de Application Support. Un bloqueo de instancia impide abrir la misma biblioteca dos veces. La interfaz y el runtime TypeScript acceden mediante comandos Rust; no abren la base directamente. [SurrealDB documenta la conexión embebida y el bloqueo de la carpeta](https://surrealdb.com/docs/reference/rust/embedding).

## Esquema

La marca `meta:schema` vale `2`. Las tablas son `recording`, `version`, `publication`, `account`, `resolver`, `recipe`, `destination`, `log`, `setting`, `job`, `memory`, `trace`, `person`, `person_voice`, `voice` y la cola privada `audio_deletion`. Cada entidad tiene una fila, con `key`, `parent` cuando corresponde, `position` para conservar el orden y `payload` como valor nativo de SurrealDB. No existe un documento JSON global. Grabaciones, versiones y jobs exponen además campos consultables directamente: `title`, `status`, `createdAt`, `backend`, `state` y `recordingId`. Cada tabla tiene un índice único en `key`; versiones, recibos, jobs, memorias, trazas y huellas tienen índice en `parent`. [Los índices únicos y normales son parte del esquema SurrealQL](https://surrealdb.com/docs/reference/query-language/statements/define/indexes).

La caché en memoria de `Store` conserva el contrato del frontend, pero cada sustitución se traduce a diferencias entre filas. Grabación, versiones y recibos, junto con las memorias, trazas y jobs eliminados al descartar y la petición de borrar su audio, se confirman en una sola transacción. Si falla una sentencia, la transacción se cancela y la caché permanece sin cambios. SurrealKV 3.3 usa sincronización de WAL en cada commit por defecto; el código no configura un modo de sincronización más débil. [SurrealDB describe las transacciones del SDK](https://surrealdb.com/docs/reference/rust/concepts/transaction).

Descartar deja una lápida con solo `id`, `source`, `sourceKey`, `legacyKey` y `status: discarded`; no conserva título, transcripciones, versiones, resúmenes, datos, recibos ni la ruta de la copia. La biblioteca visible omite esas lápidas y la vigilancia las usa para no reincorporar el origen. La cola `audio_deletion`, separada del registro y de las respuestas a JavaScript, conserva la ruta de la copia y su identidad de dispositivo e inodo. Tras confirmar la transacción y al abrir la biblioteca, Rust comprueba que sigue siendo un archivo normal dentro de `audio`, con la misma identidad y sin referencias de otra grabación, antes de borrarlo y retirar la petición. Si el borrado falla, queda pendiente para otro arranque; el archivo de origen, las publicaciones externas y las huellas ya aprendidas por Personas permanecen intactos.

`Store::open` convierte automáticamente el `library.json` de la primera versión cuando aún no hay datos en SurrealDB. Ese fichero solo se lee y queda intacto. Si encuentra filas SurrealDB del esquema `1`, convierte sus cadenas JSON a objetos nativos en una transacción y actualiza la marca a `2`. Un error de esquema o una fila corrupta detienen la apertura con un error visible; no se arranca con una biblioteca vacía.

Al actualizar, `Store::open` retira una sola vez las asignaciones de receta guardadas en grabaciones anteriores, cuya procedencia no constaba. La elección explícita hecha al incorporar una nota nueva se conserva; sin ella, el runtime consulta la receta por defecto vigente al procesarla. Cada versión y traza mantienen la receta que se ejecutó.

Los trabajos conservan `automatic`, que distingue lo incorporado por el pipeline
de las acciones manuales incluso tras reintentos o reinicios. Un proceso
completado devuelve y conserva `versionId`; el aviso de transcripción usa esa
versión y solo se envía después de confirmar el trabajo. Un trabajo cancelado
no confirma el resultado ni emite el aviso.

Las capturas que quedaron pendientes de incorporar se recuperan con la fecha
de modificación de su archivo como `createdAt`, conservada al reabrir la
biblioteca. La recuperación no les asigna la fecha del reinicio.

## Personas y huellas privadas

`person` conserva los nombres; `person_voice`, las huellas aprendidas con su modelo, origen y fecha; `voice`, las huellas de cada versión de transcripción. Estas tablas se consultan en Rust y no forman parte del documento que recibe la WebView o el runtime. La interfaz obtiene nombres y metadatos de las huellas, `hasVoices` en las versiones y reconocimientos `{speaker, person, distance}`. Las respuestas a JavaScript rechazan cualquier campo de embedding.

Al transcribir, Rust extrae las huellas del resultado nativo, reconoce por la huella más cercana del mismo modelo con umbral de distancia coseno 0,30 y conserva una asignación de persona por hablante, sin repetir persona en la nota. Las huellas quedan pendientes en Rust hasta guardar la versión. La versión y sus huellas se confirman juntas; las correcciones pueden enseñar la voz en esa misma transacción. `sourceVersionId` permite copiar las huellas al reutilizar una transcripción o corregir hablantes sin repetir reconocimiento. Una transcripción diarizada sin huellas se vuelve a diarizar.

«Registrar voz» usa `voice-samples` dentro de la carpeta privada de la app y no incorpora una nota. Exige al menos 30 segundos de habla del hablante dominante, guarda su huella y elimina la muestra al terminar o cancelar. Al arrancar se retiran las muestras de cierres interrumpidos. Quitar una persona no modifica los nombres de las notas; borrar una versión elimina sus huellas propias y conserva las ya aprendidas por personas.

Además del micrófono, se puede elegir un archivo de audio. Rust copia el archivo a `voice-samples`, extrae la huella con la misma validación y elimina esa copia al terminar o fallar. El archivo elegido permanece intacto y el audio no se publica ni se incorpora a la biblioteca.

## Archivos locales

La raíz de Application Support, SurrealKV y las carpetas de audio y credenciales tienen permisos `0700`; las copias de audio, `0600`. Esto restringe el acceso de otros usuarios locales del equipo, sin cifrar la biblioteca.

Para carpetas vigiladas, `sourceKey` incluye la carpeta y la identidad estable del archivo. Una nota de voz renombrada conserva la misma grabación y versiones; si cambian sus bytes se guarda una nueva copia de audio y se marca pendiente. Una nota inicialmente vacía se puede recuperar por esa identidad aun después de renombrarse. La importación manual conserva su deduplicación por hash de contenido.

## Comprobaciones

`cargo test --lib store::tests` ejercita datos sintéticos: reinicio, versiones, recibos, ajustes, jobs, memorias, trazas, consulta de campos nativos, conversión del esquema anterior, rollback ante una restricción real de SurrealDB, borrado transaccional, identidad estable de una nota de voz renombrada y recuperación tras matar el proceso inmediatamente después de un commit. No usa bibliotecas ni credenciales reales.
