# Example external provider

This project is installed and built as a standalone recipe project. `src/conectores.ts` registers a provider with an API key kept apart from the configuration, a Zod form, collection options fetched through `host.fetch`, and a publication cycle with a receipt. `src/recetas/ejemplo/receta.ts` shows reads and writes from a recipe through `api.cuenta(...).fetch`, without access to the key's value.

1. Copy this folder anywhere outside the repository.
2. Choose it in Escriba under **Recetas → Cambiar…** (Recipes → Change…). The app prepares `.escriba/deps/conectores` and the `escriba` launcher, without changing the sources.
3. Run **Dependencias** (Dependencies) and **Construir** (Build) from the editor, or `./escriba install` and `./escriba build` from the terminal.
4. In **Conectores → +** (Connectors → +), choose **Notas de ejemplo** (the example provider) and set up its account. Replace `mi-cuenta-sintetica` in the recipe with that account's name or ID.

You do not need a checkout of Escriba to build it. The package uses the managed copy bundled with the app; the npm version of Zod is installed in this project. To distribute the built integration, `dist/` is enough, without `.escriba`, sources or `node_modules`.

`https://api.example.test` is a fictitious domain: the example does not contact a real service. To try it, replace that origin with a synthetic local server (for example, `http://127.0.0.1:3000`) and set up the account in Escriba. The server must offer `GET /me`, `POST /drafts`, `GET /workspaces/:id/collections`, `GET /workspaces/:id/collections/:id/notes/by-key/:key`, `POST /workspaces/:id/collections/:id/notes`, and `PUT` and `DELETE` on `/workspaces/:id/collections/:id/notes/:id`. The lookup by key makes it possible to reconcile a creation whose response was lost. If a creation left pending does not show up, the example fails and requires a manual decision before any other write.
