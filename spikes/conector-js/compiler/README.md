# Compiler spike (throwaway)

Run from the spike root after `npm install`:

```sh
swift compiler/compile.swift . project/destino.ts .scratch/destino.js
```

The three arguments are the project root, an entry path relative to that root, and the bundle output path. The script loads `node_modules/esbuild-wasm/lib/browser.js` and `esbuild.wasm` into a real JavaScriptCore context. Swift serves file reads only from inside the project root (including symlink targets). esbuild produces a self-contained IIFE assigned to `globalThis.__destino`. The output's `.metadata.json` sidecar lists input files, byte count, and compatibility shims.

The fixture `compiler/fixtures/entry.ts` covers `zod/v4`, nested `node_modules`, conditional exports, a wildcard subpath, and JSON. Its local packages are versioned under `compiler/fixtures/packages/`; `compiler/fixtures/install-manifest.json` maps `parent` to `node_modules/@fixture/parent` and `leaf` to `node_modules/@fixture/parent/node_modules/@fixture/leaf` in a scratch project. Install them there before compiling the fixture. Its exported `run()` returns `{ answer: 42 }` without network access. `compiler/fixtures/nodefs.ts` demonstrates the clear rejection of `node:fs`.

This is a scoped resolver, not a full npm implementation. It handles `main`, `module`, string `browser`, `exports` with `import`/`require`/`browser`/`default` conditions and subpaths, and `.ts`, `.tsx`, `.js`, `.mjs`, `.cjs`, `.json`. It does not implement package `imports` (`#...`), browser object remaps, remote URLs, arbitrary Node builtins, or native addons. Notion SDK's optional `require("crypto")` in its webhook helper is shimmed with a throwing module so the package can bundle for browser use; webhook signing and verification remain unsupported without Web Crypto. All other Node builtins fail compilation. The post-build residual check recognizes literal `node:` imports only; it does not prove that arbitrary dynamic `import(expression)` or `require(expression)` calls are absent. A production activation path must reject or otherwise constrain those before treating a bundle as self-contained.
