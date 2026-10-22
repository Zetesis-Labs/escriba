# Example local knowledge

This project installs an ontology of meetings and agreements into the Escriba library. The first migration defines two tables and a relation; the second adds to the agreement a reference to a segment of the note. The recipe transcribes a note, looks up that segment through `api.grafo("escriba")`, creates the meeting and the agreement, queries the edge and links the note's version to the ontology records. The first sentence is used as sample text, without inferring that it is a real agreement.

1. Copy this folder outside the repository and choose it in **Recetas → Cambiar…** (Recipes → Change…). Escriba prepares the `surrealdb` SDK in `.escriba/deps/`.
2. Build the project from the editor or with `./escriba build`.
3. Install or update **Reuniones y acuerdos** (Meetings and agreements) to v2 from **Ontologías** (Ontologies). Migrations are applied once; the recipe cannot modify the schema. The `escriba` base v1 is already available and needs no installation.
4. Run the recipe on a test recording that produces at least one segment. The meeting, the agreement, its reference to the segment and its links to the note will appear in **Conocimiento** (Knowledge).

The migrations in `src/ontologias.ts` use SurrealQL to define tables, fields and relations. For safety, installation excludes `EVENT`, `TABLE AS SELECT` views and `REFERENCE ON DELETE THEN` actions, as well as authentication changes and session commands. The recipe imports the official SDK, uses `create`, `relate` and `query`, and receives a preconfigured data connection through `api.grafo`. The response types in `query<…>` are up to the recipe author; Escriba does not generate TypeScript types from SurrealQL.
The agreement's reference is stored as `{ontologyId:"escriba",table:"segment",id}`. The ID comes from the query on the existing segment; there are no SQL queries across the two databases.
