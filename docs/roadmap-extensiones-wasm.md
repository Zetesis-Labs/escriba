# Roadmap: extensiones de Escriba en WebAssembly

Encargo de Rubén el 2026-10-06: terminar lo que el spike
(`docs/spike-conectores-wasm.md`) dejó medido pero sin hacer. Una fase se da
por hecha cuando funciona hasta la pantalla, con tests, y Rubén puede
probarla en la app instalada. Cada fase es un PR.

## Fase 0: medir el modelo de comando bajo wasmtime

La única salida barata a la directiva interna del runtime de Swift es volver
al modelo de comando (una instancia por llamada, `await` de nivel superior).
Con wasmtime instanciar cuesta 5 ms; falta saber cuánto cuesta arrancar
Foundation por llamada bajo un JIT.

- Salida: tiempo de `describe`, `form` y `publish` en modo comando bajo
  wasmtime, anotado en el spike y en el ADR 0001. Decide la fase 2.

## Fase 1: wasmtime como runtime del host

- `Vendor/wasmtime/` descargado por `scripts/fetch-wasmtime.sh` (versión y
  checksum fijados, macOS arm64 y Linux x86_64; no se commitea el binario).
- Target `CWasmtime` (`systemLibrary`) y `PluginModule` sobre la API C:
  WASI nativo (entorno, `zoneinfo` pre-abierto, stdio al log), los tres
  imports del host, caché precompilada (`.cwasm`) junto al plugin, y **época**
  como tiempo límite por llamada (un plugin colgado se corta).
- WasmKit y swift-syntax salen del paquete; los tests del host usan
  `wasmtime_wat2wasm`.
- La app empaqueta `libwasmtime.dylib` en `Contents/Frameworks` y la firma;
  el CI de Linux compila `EscribaPlugins` con la dylib de Linux.
- Salida: los tests de hoy en verde sobre wasmtime; `form` del plugin OKF en
  la app por debajo de 20 ms; `.cwasm` reutilizado entre arranques.

## Fase 2: contrato sin la directiva interna

Según la fase 0:

- Si el comando sale barato (< 50 ms por llamada con Foundation): los
  plugins vuelven a comando, `handle` y `swift_task_donateThreadToGlobalExecutorUntil`
  desaparecen del kit, y el host no mantiene sesiones.
- Si no: se queda el reactor y la directiva, documentada como deuda con
  aviso de compilación.

## Fase 3: `EscribaFoundation` (ADR 0001)

Target sin `import Foundation` del que dependen los targets portables.

1. `EscribaFoundation` con tests: fecha gregoriana (día, mes, año, hora
   desde segundos; ISO 8601; «5 de octubre de 2026»), zona horaria por
   offset fijo que el host pasa en la petición, `Data` mínimo, JSON
   (codificador y decodificador propios sobre `Codable`), recorte de
   espacios, reemplazo, división, quitar tildes, `URL` mínima (host y ruta).
2. `EscribaCore` migrado; la suite entera en verde sin cambiar un test.
3. `EscribaOKF` y el plugin OKF migrados; **medir** tamaño y latencia bajo
   wasmtime y WasmKit.
4. `EscribaNotion`, `EscribaEngine`, `EscribaOpenAI` y `EscribaPluginKit`.
5. El CI comprueba que ningún target portable importa Foundation y que el
   plugin OKF pesa menos de 2 MB.

Salida: plugins de menos de 1 MB, compilación del módulo y caché triviales,
sin `zoneinfo`.

## Fase 4: los conectores de serie son plugins

- `okf.wasm` y `notion.wasm` se compilan en el CI, van dentro de la app y se
  registran al arrancar como plugins de serie (no se pueden quitar, sí
  reemplazar por una versión importada).
- Las configuraciones de los conectores nativos migran a configuración de
  plugin al primer arranque (el token, de `secrets/<id>.token` a la clave
  del plugin).
- `NotionEditor`, `OKFEditor`, `NotionModel`, `OKFModel` y los sinks nativos
  desaparecen de la app: una sola descripción de cada pantalla. `EscribaNotion`
  y `EscribaOKF` siguen existiendo, pero solo los usan los plugins y el CLI.
- Publicación real en Notion con el plugin, verificada contra la base de
  Rubén antes de borrar el camino nativo.

## Fase 5: hooks (`docs/requisito-hooks-wasm.md`)

Mismo runtime, mismo kit, mismo registro: tres eventos, N hooks en orden,
decisiones en JSON, tiempo límite por época. Sección «Hooks» en la barra
lateral con importación en caliente y prueba con la nota de ejemplo.

## Fase 6: plugins que no son Swift

Documentación del contrato para otros lenguajes (un plugin de ejemplo en
Rust `no_std` o AssemblyScript, compilado en el CI) para la idea del MCP que
genera plugins en caliente. Sin esto el ecosistema son solo los dos de serie.

## Orden y estado

| Fase | Estado |
|---|---|
| 0 | en curso |
| 1 | pendiente |
| 2 | pendiente |
| 3 | pendiente |
| 4 | pendiente |
| 5 | pendiente |
| 6 | pendiente |
