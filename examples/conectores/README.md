# Proveedor externo de ejemplo

Este proyecto se instala y construye como un proyecto de recetas independiente. `src/conectores.ts` registra un proveedor con clave de API separada de la configuración, formulario Zod, opciones de colección obtenidas por `host.fetch` y un ciclo de publicación con recibo. `src/recetas/ejemplo/receta.ts` muestra consultas y escrituras desde una receta mediante `api.cuenta(...).fetch`, sin acceso al valor de la clave.

1. Copia esta carpeta a cualquier ubicación fuera del repositorio.
2. Elígela en **Recetas → Cambiar…** de Escriba. La app prepara `.escriba/deps/conectores` y el lanzador `escriba`, sin cambiar las fuentes.
3. Ejecuta **Dependencias** y **Construir** desde el editor, o `./escriba install` y `./escriba build` desde el terminal.
4. En **Conectores → +**, elige **Notas de ejemplo** y configura su cuenta. Sustituye `mi-cuenta-sintetica` en la receta por el nombre o ID de esa cuenta.

No se necesita el checkout de Escriba para construirlo. El paquete usa la copia administrada que incluye la aplicación; la versión npm de Zod se instala en este proyecto. Para distribuir la integración ya construida basta `dist/`, sin `.escriba`, fuentes ni `node_modules`.

`https://api.example.test` es un dominio ficticio: el ejemplo no contacta con un servicio real. Para probarlo, sustituye ese origen por el de un servidor local sintético (por ejemplo, `http://127.0.0.1:3000`) y configura la cuenta en Escriba. El servidor debe ofrecer `GET /me`, `POST /drafts`, `GET /workspaces/:id/collections`, `GET /workspaces/:id/collections/:id/notes/by-key/:key`, `POST /workspaces/:id/collections/:id/notes`, `PUT` y `DELETE` sobre `/workspaces/:id/collections/:id/notes/:id`. La consulta por clave permite reconciliar una creación cuya respuesta se perdió. Si no aparece una creación que quedó pendiente, el ejemplo falla y exige decidir manualmente antes de otra escritura.
