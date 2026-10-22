# @escriba/conectores

Notion and OKF publications run in TypeScript. The host provides HTTP, access
to a folder, the audio and persistence of the receipt. This package contains no
credentials, and no provider endpoints or formatting rules live outside it.

`run(request, host)` is the compatibility interface for earlier
configurations. `manifest`, `validate` and configuration migration are
operations without external effects. `preview` accepts a note or uses the app's
example. `discover` lists Notion sources or OKF documents. `publish` and
`remove` carry out the effects and return `{ locator, url?, receipt }`.

```ts
import { createProgram, defineNotionDestination } from '@escriba/conectores';

const program = createProgram([
  defineNotionDestination({
    id: 'actas',
    name: 'Actas del equipo',
    account: 'mi-cuenta',
    configuration: {
      source: {
        id: 'data-source-id',
        title: 'Actas',
        properties: [{ name: 'Nombre', type: 'title' }],
      },
      columns: { Nombre: '{{titulo}}' },
      body: '# Resumen\n{{resumen}}\n# Texto\n{{transcripcion}}',
    },
  }),
]);

export const inspect = program.inspect;
export const run = program.run;
```

`defineOKFDestination` uses the same contract. Its configuration holds `folder`
and, optionally, `documents`, with `id`, `name`, `path`, `properties` and
`body`. Existing IDs are kept, and `{{enlace:id}}` references are resolved
before changes are applied. A destination can declare `inputSchema` with Zod
and `prepare(input, request)` to turn its own data into the published note.

The host must store each `checkpoint` durably before resolving it, and
serialize operations that share a destination or folder. The receipt is opaque
to the host. OKF stores SHA-256 hashes of all its paths and of the pending
plan; an interrupted write resumes from that receipt. A manual edit to a
published document makes the operation fail before the folder is modified.
Changing a receipt's folder requires resolving the move explicitly.

Notion uses the official SDK, in batches of a hundred blocks. Before a page is
created, a receipt with `state: 'creating'` and `locator: ''` is saved; the
host must persist it too. Right after creation the locator is saved. If the
creation response is lost, another run looks up the key column and continues
with the page it finds. If it cannot reconcile it, it returns an explicit error
and does not create blindly again. The receipt can be completed with the
verified locator through an explicit reconciliation action of the host.

The SDK retries 429 and 529, and 500/503 errors only for GET and DELETE. It
does not retry creations on network errors. Audio is uploaded in a single part
up to 20 MiB and in 10 MiB parts above that size. Credentials are injected into
the host's HTTP transport; this package never receives tokens.

## Development

```sh
./scripts/build-conectores.sh
```

The script installs from the lockfile without running npm scripts, runs the
tests with an in-memory transport and folder, and generates types, ESM modules
and `dist/conectores.js` (`globalThis.__conectores`). The app runs the programs
with the bundled Bun, in isolated processes and with capabilities from the Rust
host.

The tests do not call real services. Validation against real Notion with
synthetic data is still pending authorization for that phase.

## Project providers

`createProgram(destinos, proveedores)` lets an external project declare providers. A provider defines its access manifest, its ordinary configuration with Zod, the forms Escriba shows and its operations. The credential is declared in `manifest.credential` and the host keeps it; it is not part of `defaultConfiguration` and is never handed to the program.

```ts
import { z } from 'zod';
import { createProgram, defineProvider } from '@escriba/conectores';

const synthetic = defineProvider({
  manifest: {
    id: 'synthetic', name: 'Synthetic', capability: 'http',
    origin: 'https://example.test', allowedHeaders: ['content-type'],
    credential: { label: 'Clave', header: 'Authorization', prefix: 'Bearer ' },
    defaultConfiguration: { project: 'demo' },
  },
  configurationSchema: z.object({ project: z.string().min(1) }),
  describe: (configuration) => ({
    view: { sections: [{ title: 'Proyecto', fields: [
      { type: 'text', path: ['project'], label: 'Proyecto' },
    ] }] },
  }),
  run: async (request, host) => {
    if (!host) throw Error('Falta el host de capacidades');
    const response = await host.fetch('https://example.test/projects/' + request.config?.project);
    return { resource: await response.json() };
  },
});

const program = createProgram([], [synthetic]);
export const inspect = program.inspect;
export const run = program.run;
```

`inspect()` returns serializable providers and destinations. `run({ operation: 'describe', provider, config, state })` delivers a declarative `view` with no host authority. `action` can query the service through `host.fetch` and return `{ configuration, state, view }`; `state` keeps only temporary selection and options, never credentials. `validate` reports invalid fields by their Zod path. Account and publication operations are delegated to the provider's `run`. The built-in Notion and OKF providers use this same forms contract.

`manifest.connectAction` names the action that runs after a new credential is saved; Notion uses `refresh-sources`. Selectors whose value lives in the temporary state can declare `field.value` even when `field.path` is empty. The definition accepts Zod instances installed by the external project; their schema must offer `parse`, `safeParse` and `toJSONSchema`.

The [example external project](../../examples/conectores/README.md) shows a provider with dynamic options, an API key, publication with a receipt, and a recipe that reads and writes through the authorized account.
