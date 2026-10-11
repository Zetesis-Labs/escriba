# El conocimiento se instala por ontología en una base separada

Las recetas necesitan compartir entidades y relaciones entre notas sin convertir
el proyecto de código en propietario de los datos. El grafo se guarda en
`knowledge.surrealkv`, separado de la biblioteca de notas, con una base lógica
por ID estable de ontología. El proyecto propone definiciones, pero la persona
usuaria instala o actualiza cada ontología de forma explícita. Su versión y sus
registros permanecen al cambiar de proyecto. Cada receta declara el intervalo
`minVersion`/`maxVersion` que admite; Rust lo contrasta con el catálogo instalado
en cada acceso.

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
ontologías, embeddings gestionados ni un canvas.

Un registro puede vincularse a varias versiones de nota. La UI puede editarlo
mediante formularios declarados con control de revisión; el host protege esas
correcciones manuales frente a escrituras de recetas. Una consulta raw puede
acceder a tablas propias de la ontología según sus permisos; para vincular un
registro a una nota, la tabla debe estar en `collections`. Toda consulta raw
activa antes el marcador duradero que bloquea el reintento automático,
porque el SQL puede tener efectos incluso si la llamada parece de lectura. La
prueba `dryRun` deniega el grafo hasta disponer de una ejecución reversible.

La implementación y las pruebas de esta decisión están en la rama de trabajo;
este ADR no equivale a validar una instalación final por la persona usuaria.
