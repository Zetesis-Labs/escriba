# El conocimiento se instala por ontología en una base separada

Las recetas necesitan compartir entidades y relaciones entre notas sin convertir
el proyecto de código en propietario de los datos. El grafo se guarda en
`knowledge.surrealkv`, separado de la biblioteca de notas, con una base lógica
por ID estable de ontología. La base integrada `escriba` está siempre disponible;
el proyecto propone extensiones, pero la persona
usuaria instala o actualiza cada ontología de forma explícita. Su versión y sus
registros permanecen al cambiar de proyecto. Cada receta declara el intervalo
`minVersion`/`maxVersion` que admite; Rust lo contrasta con el catálogo instalado
en cada acceso. La dependencia de `escriba` v1 es implícita, salvo que la receta
declare explícitamente otro intervalo compatible.

La base publica las identidades canónicas de Personas y Biblioteca: personas,
grabaciones, versiones, transcripciones, hablantes, segmentos y palabras, junto
con sus relaciones. Se muestra en Ontologías separada de las extensiones, con
campos y extremos de cada relación desplegables. La aplicación es propietaria de
este esquema; una extensión no puede usar el identificador `escriba`. Si una
instalación anterior ya lo usaba, la apertura falla sin sustituir sus datos.

La biblioteca sigue siendo la fuente de verdad. Una cola privada duradera marca
los cambios de persona o grabación en la misma transacción que los confirma.
Antes de consultar la base, el host proyecta cada entidad pendiente en una
transacción y acusa recibo sólo de la revisión aplicada. Un identificador de la
proyección permite reconstruirla si se recrea el almacén de conocimiento. No se
carga toda la biblioteca en memoria ni se replican las personas en cada
extensión. Los borradores no entran en la proyección hasta confirmarse. Rutas de
audio, credenciales, huellas de voz y datos arbitrarios de recetas quedan fuera.

Las recetas consultan la base con `api.grafo("escriba")`. Un validador del AST
rechaza escrituras y control de sesión, además de los permisos de sólo lectura
de las tablas. Las modificaciones de Biblioteca y Personas siguen usando sus
operaciones habituales. La asignación de una persona conserva su UUID en el
segmento; los nombres históricos no se convierten en identidades por conjetura.
Un segmento se identifica dentro de su versión y no se supone equivalente a un
segmento de otra versión.

Una extensión referencia la base mediante un campo `reference` con
`{ontologyId, table, id}`. El formulario elige registros existentes de la base y
conserva una referencia anterior aunque el original se haya borrado, sin
recrearlo. Esta referencia explícita no habilita recorridos SurrealQL entre
bases lógicas: se resuelve consultando la base correspondiente por el SDK.

Una definición contiene migraciones SurrealQL consecutivas y acumulativas. Las
ya aplicadas son inmutables y las pendientes se confirman de forma atómica con
el nuevo manifiesto. Esta separación impide que procesar una nota altere el
esquema o que seleccionar otro proyecto borre registros compartidos. Las
migraciones pueden definir el esquema de datos, pero excluyen `EVENT`, vistas
`TABLE AS SELECT` y acciones `REFERENCE ON DELETE THEN`: en SurrealDB 3.3.2
sus callbacks podrían ejecutar trabajo con privilegios del migrador. El espacio
`_escriba_` queda reservado a vínculos, manifiestos y
protecciones del host.

La receta usa el SDK oficial SurrealDB 2.1.1 mediante un motor RPC dentro del
worker y CBOR por el canal JSONL existente. CBOR conserva los tipos nativos del
SDK; los formularios de la UI usan JSON de manera independiente. Rust ejecuta
las consultas como principal `RECORD` de una sola base, con permisos de datos
de sus tablas, sin DDL, `USE` ni autenticación administrable. No hay servidor,
socket, segunda base en el worker, red o scripting JavaScript. Los lotes SQL
`BEGIN`/`COMMIT` son posibles, pero las transacciones interactivas y `live` del
SDK quedan fuera del contrato. Tampoco se crean cruces automáticos entre
ontologías ni embeddings gestionados.

Ampliación encargada por Rubén el 2026-10-11: Ontologías incorpora un mapa de
estructura y un explorador de datos con inspector, conservando la gestión de
instalaciones. El visor reutiliza algoritmos de colocación de GraphMarks;
las relaciones dirigidas, paralelas y los bucles conservan identidad propia.
Rust entrega páginas de colecciones y vecindades declaradas, incluidas las
referencias a la base y la procedencia. La WebView no recibe la base completa
ni ejecuta SurrealQL. Esta vista de lectura no añade relaciones implícitas ni
descubre tablas raw ajenas al manifiesto. Alcance y criterios en
`specs/escriba/mapas-conocimiento/functional-specs.md`.

Un registro puede vincularse a varias versiones de nota. La UI puede editarlo
mediante formularios declarados con control de revisión; el host protege esas
correcciones manuales frente a escrituras de recetas. Una consulta raw puede
acceder a tablas propias de la ontología según sus permisos; para vincular un
registro a una nota, la tabla debe estar en `collections`. Toda consulta raw de
una extensión
activa antes el marcador duradero que bloquea el reintento automático,
porque el SQL puede tener efectos incluso si la llamada parece de lectura. Las
lecturas de la base integrada no activan ese marcador. La
prueba `dryRun` deniega el grafo hasta disponer de una ejecución reversible.

La implementación y las pruebas de esta decisión están en la rama de trabajo;
este ADR no equivale a validar una instalación final por la persona usuaria.
