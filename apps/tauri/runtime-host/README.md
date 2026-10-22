# Bun controller and isolated workers

The WebView only imports `src/runtime/index.ts`, an IPC client. Rust supervises
the Bun controller; the controller opens `library.rocksdb` before announcing
`ready` and maintains the library, the durable queue, the credentials, the HTTP
transport and the rules for recipes and connectors. Recipe workers run
separately and do not receive credentials, audio paths or voiceprints. Rust
keeps the knowledge graph and the native and system capabilities.

## Build

```sh
node apps/tauri/runtime-host/build.mjs \
  apps/tauri/src-tauri/binaries/escriba-runtime-aarch64-apple-darwin \
  aarch64-apple-darwin
```

It requires installed npm dependencies and the Bun version pinned in
`bun-version`. `buildRuntime({output,bun,target})` bundles the SDK, Zod, the
controller and the worker/connector programs into a standalone executable. It
disables loading of `.env` and `bunfig.toml` and the automatic installation of
imports. The binary is signed before it is tested and signed again when the app
is packaged. The end user does not need to install Bun, Node or npm.

The app build uses esbuild as a development dependency. The distributed
executable builds recipe projects with `Bun.build` and produces
`dist/escriba.json` and the JavaScript bundles. No other esbuild executable is
distributed. The loader only reads `dist/`: the sources and `node_modules` are
needed to build it, not to run it.

The `--project-build` mode has a separate development sandbox: it can read the
project and the bundled dependencies, and write inside the project.
`project_tool` exposes installation without lifecycle scripts, type-checking
with the native Go TypeScript 7.0.2, and tests with Bun. Only installation is
allowed network access. These processes do not receive note capabilities or
credentials. The CodeMirror editor calls these operations; it does not run code
in the WebView. The [project contract](../../../docs/proyecto-recetas-tauri.md)
describes the artifact, the tools and their limits.

## Protocol v1

UTF-8 JSONL over stdin/stdout. The host announces
`{type:"ready",protocolVersion:1}`. Request IDs: a string or a safe integer.

Each frame has a maximum of 32 MiB in UTF-8 bytes, in both Rust and TypeScript.
If a capability response exceeds that size, Rust sends a readable rejection and
keeps the session for the next job. Errors while reading the protocol keep their
cause in the job's error.

- Rust → host: `command {id,method,params,origin}` (`origin` is `ui` or
  `shell`), `cancel {id}` and `shutdown {id}`. The shutdown lets the controller
  exit so it releases the RocksDB lock before being restarted.
- Host → Rust: `result {id,value}`, `error {id,message,code}`.
- Host → Rust: `call {id,method,params,taskId}`; responses `resolve {id,value}`
  or `reject {id,message,code}`. `taskId` keeps the execution ID even when
  answering a recipe's capabilities.
- Host → Rust: `event {event,value}` for `changed`, `jobs`, `status`, `log`,
  `imported`, `project`, `voice-registration` and `whisper-download`.
- Host → Rust: `worker_create {id,taskId}`, `worker_send {id,value}`,
  `worker_terminate {id}`.
- Rust → host: `worker_message {id,value}`, `worker_error {id,message}`.

Rust creates each worker by running the same binary with `--worker`, a clean
environment and exclusive pipes. This mode consumes `start/resolve/reject` and
produces `call/result/error`, the protocol of the existing Worker adapter. Rust
forwards its messages to the controller, which validates each operation in the
context of the authorized note and account. A maximum of eight simultaneous
workers. Rust must terminate their processes when the host is closed or
restarted and enforce the total time limit of the job.

The worker always runs a compiled program. A form recipe with no base runs a
built-in program: `build.mjs` builds *Por defecto*, Transcribir, Resumir and
Publicar from `recetas/<programa>/receta.ts` into the `__BUILTIN_RECIPES__` map,
with Zod shared with the worker, and the controller indicates which one in
`payload.builtin`. Forms with a language take the one from the settings.
*Por defecto* is composed in its code from the pieces in `recetas/piezas.ts`;
Rust copies those two files when a project is started and a test checks it.
The capability wait time does not consume the adapter's CPU budget.

The codes `backend_unavailable`, `recipe_unavailable` and `runtime_unavailable`
allow a retry; `microphone_denied` and `failed` remain a terminal failure. An
error message without a known code is treated as `failed`, even if its text
contains an old marker. Rejections from capabilities and workers keep the code
all the way to the durable queue.

Projects can contribute providers with declarative forms. The controller runs
`connectorEditor` in a worker: describing and validating do not grant
capabilities; an explicit action accesses the account that the UI indicates.
Provider code is not run in the WebView, and those actions are not repeated when
jobs are recovered. Results are validated against `ConnectorView` before they
are rendered.

The fetch of `escriba.cuenta(id)` uses `account.http`. Each request re-reads the
authorization in the controller, checks `expectedGrant`, origin and headers, and
injects the secret there. An SDK write first confirms `accountEffectPending` on
the recording; it is kept even after finishing, to cover a shutdown before the
job's acknowledgment. A new manual run removes the marker; an automatic,
recovered or retried job is blocked. SDKs may have their own retries: the recipe
must disable them or ensure idempotency when it modifies resources.

`api.grafo(id)` asynchronously opens the official `surrealdb` 2.1.1 SDK through
an `RpcEngine` over the worker's existing calls. `graph.open` obtains the
installed version after checking the dependency declared by the recipe;
`graph.query` sends SQL and parameters as CBOR/base64 to `knowledge_query`. The
response comes back as CBOR/base64 as a list of statement results. The bridge
preserves SurrealDB types such as `RecordId`, `DateTime` and `Decimal` and does
not require a server, a socket or a second database instance in the worker. The
database identity and the authentication are fixed by Rust; neither the recipe
nor the SDK can choose them. `nota.vincular(ontologiaId, recordId)` calls
`graph.link` with the identifier of the note's active version and only accepts
records from tables declared in `collections`. A raw query can use other tables
of that database if their SurrealQL permissions allow it.

`api.grafo("escriba")` uses the same SDK and RPC for the internal v1 database,
installed implicitly and read-only. The recipe can query recordings, people,
versions, transcripts, speakers and segments, with their words in
`segment.words` and their segments by reference (`transcript<~segment`); the
library is synchronized before reading. An incompatible explicit dependency
fails on open. `nota.vincular("escriba", …)` is rejected because that database
is already derived from the library. A `reference` field in another ontology
stores `{ontologyId:"escriba",table,id}` as an object, with no SQL traversal
between databases.

On every operation, Rust verifies the ID, the version range persisted in the
recipe's catalog and the exact version returned when the connection was opened.
The query runs as `RECORD` in a single logical ontology database, with data
permissions defined by its tables, without DDL, `USE` or authentication
administration. The SDK allows its data methods and `query`, including
SurrealQL batches with `BEGIN`/`COMMIT`. It offers no interactive transactions
or `live`. Installation and migrations use another identity outside the worker.
The database denies network access and JavaScript scripting; user migrations
cannot create `EVENT` or `TABLE AS SELECT` views because in SurrealDB 3.3.2
they would run code with the migrator's privileges.
They also exclude `REFERENCE ON DELETE THEN` actions for the same reason.

In `dryRun`, all graph calls are denied. Before any `graph.query`, the
controller confirms the durable marker `accountEffectPending`: raw SQL can write
and is not safe to repeat after an uncertain shutdown. A new manual reprocess
can start another run. The JSONL RPC carries the base64 strings within the
general 32 MiB limit; Rust additionally limits SQL and parameters to 1 MiB and
CBOR results to 8 MiB.

The controller obtains `runtime_context({recordingId?})` from its library:
catalogs, processing settings and only the requested recording with its
versions and receipts. Workers receive this limited context, with no records
from other recordings, watched folders, credentials, voiceprints or audio paths.
The total size of the library does not determine the size of each job. The
folder's fingerprint makes it possible to invalidate an operation if its
destination changes while it runs.

`processRecording` accepts `options.values` for the parameters of a single run.
If omitted, it uses the ones saved in the recipe; if sent, it replaces those
values, including `{}` to use the built-in ones. It does not save the change and
only applies it to the chosen recipe: recipes called with `procesar` use their
own values. `getRecipeSchema` returns `null` when a code recipe does not export
`buildRecipeForm`.

## Isolation

Rust starts the controller without `sandbox-exec`, with the data root and the
SurrealDB N-API binding in its environment. Each recipe worker uses
`/usr/bin/sandbox-exec` and the `sandbox.sb` profile. The profile starts from
`deny default`; it allows reading its own executable and the macOS libraries and
their ICU data from `/usr/share/icu`, but denies user files, writing, network
and new processes.
The Bun/Node APIs still exist: the restriction is enforced by macOS.

Each recipe has its own pipes. Writing a fake frame to stdout does not grant
access to the controller's privileged channel: the controller validates the
worker's messages and the validity of the job; Rust only serves the capabilities
of its shell and of the knowledge graph. Startup errors keep up to 2 KiB of
diagnostics; the recipes' stderr is drained without publishing or storing it.

The profile has been tested on macOS 26 with Bun 1.4.2. `sandbox-exec` is
deprecated in Apple's manuals and the tests must be repeated whenever macOS or
Bun changes. A sandbox failure prevents startup, with no unprotected fallback
execution. Sources and compatibility tests are in
[the Bun research](../../../docs/investigacion-bun-sandbox.md).

## Evidence

`tests/runtime/sidecar.test.ts` builds and launches the real executable with a
fake host over pipes: it saves before summarizing, restarts without repeating
the transcription, cancels a CPU-bound recipe, checks that files and network are
denied, and rejects a forged capability sent through the recipe process's
stdout. It uses only fixtures, temporary files and a synthetic local server. It
also checks that `node:child_process` and `Bun.spawnSync` cannot relaunch the
executable itself.

The Rust tests in `scripts` exercise the built executable with a synthetic
library larger than 32 MiB and check that it can process a note. Another test
builds a project with a local dependency in `node_modules` and runs its recipe
until it saves a version. The memory test uses the real Rust supervisor; the
TypeScript harness does not simulate that supervisor. `runtime_context` is
validated with RocksDB in the Bun library tests, preserving the versions and
receipts of the chosen note and excluding other data.

## Parity with the previous library

The review of `RecipeSession` and `NoteMemory` found three losses of state,
which have been fixed in the controller: repeated questions on resume, repeated
summary inferences after completion, and the absence of test traces.
`memory_recall/memory_keep` store answers by recording, version and canonical
SHA-256 of the request, model, URL and instructions/schema. The answer is
validated before it is stored. Summary chunks and reductions are remembered
before the version's summary is updated. A new manual version has its own
memory. Tests do not write versions or memory, and keep their result in
`trace_save`.

The **Registro** (Log) shows durable jobs, retries and traces with the duration
of each step. Capture is recovered by querying the recording process; the
WebView does not reconstruct that state or re-enqueue recordings when it opens.
The migration is offered explicitly in **Ajustes** (Settings) and keeps the
source library. Permanently deleting notes requires confirmation and does not
remove their external publications.

Deliberate difference: an old summary with no request identity is not reused as
the answer for another model/prompt. It may be recomputed once to create the
compatible memory. Bun resolves durable storage and decides on notifications;
Rust delivers them and keeps the system permissions. Whisper/diarization,
Foundation Models and AVFoundation remain in the native process.

## Verified limits

Rust measures each worker's resident memory every 50 ms through `proc_pidinfo`
and terminates the process if it observes more than 512 MiB. It checks its
identity to avoid acting on a reused PID; if it cannot monitor it, the run
fails. The synthetic test holds memory until it exceeds the limit and verifies
that the controller keeps responding.

It is an operational limit: there may be overshoot between samples. It is not
equivalent to the former V8 old-space limit or to a strict heap quota. Bun
1.4.2's heap options did not enforce a cap in the tests; they are not used as
protection.

Recipes and connectors have ten accumulated seconds of execution between
capabilities, the same as the former JavaScriptCore default limit. The adapter
subtracts the time elapsed before each RPC and resumes it when the pending
capabilities finish. Slow inference does not consume that budget; splitting the
work into several RPCs does not reset it either. The supervisor also enforces
the total limit and terminates all child processes.

## Host type-checking

```sh
cd apps/tauri
npm run typecheck:runtime
```

It type-checks `runtime-host/main.ts` and its original imports with the
TypeScript and Node types already installed in the project. The temporary
configuration inherits the app's aliases. It is independent of the Bun
packaging; it does not install packages or need a network.
