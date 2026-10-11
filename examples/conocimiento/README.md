# Conocimiento local de ejemplo

Este proyecto instala una ontología de reuniones y acuerdos en la biblioteca de Escriba. La migración define dos tablas y una relación; la receta transcribe una nota, crea una reunión y un acuerdo, consulta la arista y vincula la versión de la nota con la reunión. El primer enunciado se usa como texto de ejemplo, sin inferir que sea un acuerdo real.

1. Copia esta carpeta fuera del repositorio y elígela en **Recetas → Cambiar…**. Escriba prepara el SDK `surrealdb` en `.escriba/deps/`.
2. Construye el proyecto desde el editor o con `./escriba build`.
3. Instala **Reuniones y acuerdos** v1 desde Ontologías. La migración se aplica una vez al instalar; la receta no puede modificar el esquema.
4. Ejecuta la receta sobre una grabación de prueba. En Conocimiento aparecerán la reunión, el acuerdo y su vínculo con la nota.

Las migraciones de `src/ontologias.ts` usan SurrealQL para definir tablas, campos y relaciones. Por seguridad, la instalación excluye `EVENT`, vistas `TABLE AS SELECT` y acciones `REFERENCE ON DELETE THEN`, así como cambios de autenticación y comandos de sesión. La receta importa el SDK oficial, usa `create`, `relate` y `query`, y recibe una conexión de datos preconfigurada mediante `api.grafo`. Los tipos de respuesta en `query<…>` los decide el autor de la receta; Escriba no genera tipos TypeScript a partir de SurrealQL.
