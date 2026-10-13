# Spike desechable: SurrealDB embebida desde Bun

Comprueba si un proceso Bun puede abrir la base de datos de Escriba sin pasar
por Rust, condición del ADR-0011 (`docs/adr/0011-dominio-en-bun-rust-cascara.md`).

## Resultado (2026-10-13, macOS arm64, Bun 1.3.0)

**Viable.** `@surrealdb/node` 3.1.0 (motor 3.3.4, binding N-API de 40 MB) con
el SDK `surrealdb` 2.1.1, el mismo que ya usan las recetas, abre una base
RocksDB y otra SurrealKV, define esquema, escribe, aborta una transacción con
`THROW` sin dejar rastro y vuelve a abrir la base con los datos. Funciona
ejecutando con `bun run` y como ejecutable de `bun build --compile` (59 MB).

Límites vistos:

- `bun build --compile` no embebe el `.node`: el binario lo busca en disco en
  `node_modules/@surrealdb/node-native-<plataforma>/`. En la app iría como
  recurso junto al ejecutable. Hay bindings para darwin y linux, x64 y arm64.
- El binario compilado muere con `SIGKILL` (137) hasta firmarlo
  (`codesign -s - -f`), como ya hace `runtime-host/build.mjs`.
- Sin probar: Bun 1.4.2 (el fijado en `runtime-host/bun-version`), abrir una
  `library.rocksdb` creada por el crate 3.3.2 de Rust, y el comportamiento
  bajo el perfil de `sandbox-exec`.

## Ejecutar

```sh
bun install
bun run spike.ts /tmp/spike-db            # RocksDB
bun run spike.ts /tmp/spike-kv surrealkv  # SurrealKV
bun build --compile spike.ts --outfile spike-bin && codesign -s - -f spike-bin
./spike-bin /tmp/spike-db2
```

## Sondas añadidas (2026-10-13, plan del ADR-0011)

- `inspect.ts <ruta> [ns db]`: namespaces y bases de un almacén, o recuentos
  por tabla de una base. Con una copia de la biblioteca real: abre y lee.
- `access.ts`, `access2.ts`, `access3.ts`: sesión `RECORD`. Resultado: `$auth`
  y `$session` se rellenan e `INFO FOR DB` se deniega, pero los `PERMISSIONS`
  de tabla **no se aplican** porque el motor de Node no permite activar la
  autenticación (`ConnectionOptions` solo admite `capabilities`, `defaults` y
  tiempos). Una segunda `Surreal` sobre el mismo RocksDB falla aunque sea en el
  mismo proceso. `BEGIN … CANCEL` funciona.
