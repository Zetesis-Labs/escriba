# Sonda de JavaScriptCore

Ejecuta un plugin de Escriba en el `WebAssembly` de JavaScriptCore, el
framework del sistema, con un shim WASI escrito en JS dentro de `main.swift`
(JavaScriptCore no trae `TextEncoder`, `atob` ni `performance`; las llamadas
WASI que faltan devuelven `ENOSYS`). Es la que dio las medidas de
JavaScriptCore de `docs/spike-conectores-wasm.md`.

```bash
cd spikes/javascriptcore
swiftc -O main.swift -o jscprobe
./jscprobe ../../.build/plugins/okf.wasm "$(mktemp -d)"
```
