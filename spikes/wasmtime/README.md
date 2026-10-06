# Sonda de wasmtime

Ejecuta un plugin de Escriba con la API C de wasmtime 49.0.2 y cronometra
cada comando. Es la que dio las medidas de wasmtime de
`docs/spike-conectores-wasm.md`.

```bash
cd spikes/wasmtime
curl -LO https://github.com/bytecodealliance/wasmtime/releases/download/v49.0.2/wasmtime-v49.0.2-aarch64-macos-c-api.tar.xz
tar xf wasmtime-v49.0.2-aarch64-macos-c-api.tar.xz && mv wasmtime-v49.0.2-aarch64-macos-c-api wasmtime-c-api
swift build -c release
.build/release/wtprobe ../../.build/plugins/okf.wasm "$(mktemp -d)"            # reactor, instancia viva
COMANDO=1 .build/release/wtprobe okf-comando.wasm "$(mktemp -d)"               # instancia por llamada
```

- Por defecto trata el módulo como reactor (`_initialize` y `escriba_handle`).
- `COMANDO=1` instancia el módulo en cada llamada, le pasa la petición por
  stdin y lee la respuesta de stdout. El módulo de comando sale de compilar el
  plugin OKF con `await runPlugin(serve)` en `main.swift` y sin los flags de
  reactor.
- `SIN_ZONEINFO=1` no pre-abre `/usr/share/zoneinfo`, para reproducir el trap.
- Compila el módulo, lo serializa a `.cwasm` y mide la carga precompilada.
