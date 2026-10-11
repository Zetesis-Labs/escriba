# Conocimiento local de ejemplo

Este proyecto instala una ontología de reuniones y acuerdos en la biblioteca de Escriba. La primera migración define dos tablas y una relación; la segunda añade al acuerdo una referencia a un segmento de la nota. La receta transcribe una nota, consulta ese segmento mediante `api.grafo("escriba")`, crea la reunión y el acuerdo, consulta la arista y vincula la versión de la nota con los registros de la ontología. El primer enunciado se usa como texto de ejemplo, sin inferir que sea un acuerdo real.

1. Copia esta carpeta fuera del repositorio y elígela en **Recetas → Cambiar…**. Escriba prepara el SDK `surrealdb` en `.escriba/deps/`.
2. Construye el proyecto desde el editor o con `./escriba build`.
3. Instala o actualiza **Reuniones y acuerdos** a v2 desde Ontologías. Las migraciones se aplican una vez; la receta no puede modificar el esquema. La base `escriba` v1 ya está disponible y no requiere instalación.
4. Ejecuta la receta sobre una grabación de prueba que produzca al menos un segmento. En Conocimiento aparecerán la reunión, el acuerdo, su referencia al segmento y sus vínculos con la nota.

Las migraciones de `src/ontologias.ts` usan SurrealQL para definir tablas, campos y relaciones. Por seguridad, la instalación excluye `EVENT`, vistas `TABLE AS SELECT` y acciones `REFERENCE ON DELETE THEN`, así como cambios de autenticación y comandos de sesión. La receta importa el SDK oficial, usa `create`, `relate` y `query`, y recibe una conexión de datos preconfigurada mediante `api.grafo`. Los tipos de respuesta en `query<…>` los decide el autor de la receta; Escriba no genera tipos TypeScript a partir de SurrealQL.
La referencia del acuerdo se almacena como `{ontologyId:"escriba",table:"segment",id}`. El ID procede de la consulta al segmento existente; no hay consultas SQL entre las dos bases.
