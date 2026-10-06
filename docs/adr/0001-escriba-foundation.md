---
status: aparcada
---

# El núcleo portable no usa Foundation: usa EscribaFoundation

> **Aparcada el 2026-10-06.** Rubén archiva el spike de plugins wasm: no
> merece la pena ahora. Sin plugins, el motivo que queda es el núcleo en
> Kubernetes (`docs/requisito-nucleo-wasm-kubernetes.md`). Si se retoma
> cualquiera de los dos, las medidas de abajo siguen valiendo.

Decisión de Rubén el 2026-10-06: `EscribaCore`, `EscribaEngine`, `EscribaNotion`,
`EscribaOKF`, `EscribaOpenAI` y el contrato de los plugins (`EscribaPluginKit`)
dejan de importar `Foundation`. En su lugar importan `EscribaFoundation`, un
target propio y pequeño que copia de swift-foundation (Apache 2.0) solo las
piezas que el núcleo necesita y escribe en casa las que son triviales. Los
hosts (`EscribaSystemKit`, `EscribaStore`, `EscribaWhisper`, la app) siguen
usando Foundation con normalidad.

## Por qué

El spike de conectores como plugins WebAssembly (rama `feat/conectores-wasm`,
commit `b2b2218`) midió lo que cuesta Foundation en un módulo wasm compilado
con el SDK de swift.org 6.4 y ejecutado con WasmKit 0.4.1:

| Módulo | Tamaño | Arranque | Llamada |
|---|---|---|---|
| Con `Foundation` | 59 MB | 850 ms | 35 ms |
| Solo `FoundationEssentials` | 57,6 MB | igual | igual |
| Sin Foundation | 6,8 MB (0,5 MB sin sección de nombres) | 0,5 ms | 0,04 ms |

- No hay término medio. Aunque solo se importe `FoundationEssentials`, el SDK
  wasm enlaza `lib_FoundationICU.a` (39,7 MB de tablas de todos los idiomas,
  calendarios y zonas horarias) porque `Calendar`, `TimeZone` y `Locale` tiran
  de `FoundationInternationalization`. Son datos, no código: el enlazador no
  los recorta.
- El arranque de 850 ms es Foundation inicializándose (ICU valida tablas,
  construye locales, registra metadatos), no WasmKit interpretando.
- `TimeZone(identifier:)` lee `/usr/share/zoneinfo`; en WASI no existe salvo
  que el host lo pre-abra, y el fallo cae en `unreachable` sin mensaje. Una
  hora de depuración por un detalle de plataforma.
- El núcleo que va a Kubernetes como componente wasm
  (`docs/requisito-nucleo-wasm-kubernetes.md`) arrastra los mismos 45 MB.

Con la idea de que un MCP de Escriba permita a Claude generar e instalar
plugins en caliente, el tamaño y el arranque dejan de ser un detalle: un
plugin debe compilar en segundos, pesar menos de 1 MB y arrancar al instante.

## Qué contiene EscribaFoundation

Copiado de swift-foundation, congelado en una versión y con su licencia y
cabeceras conservadas (`NOTICE` en el repo):

- `JSONEncoder` / `JSONDecoder` de `FoundationEssentials` (escáner y escritor
  autónomos sobre `Codable` de la stdlib).
- `Data`.
- `Date` y el cálculo gregoriano de `Calendar` (año, mes, día, hora, día de la
  semana desde segundos), sin locales.
- `TimeZone` solo con offset fijo; el host pasa el offset vigente. Si hace
  falta el lector de ficheros tz, también es Swift puro en Essentials.

Escrito en casa, porque copiarlo trae más de lo que vale:

- `trimmingCharacters`, `replacingOccurrences`, `components(separatedBy:)`,
  `hasPrefix`/`hasSuffix` sobre la stdlib.
- Quitar tildes (`folding(.diacriticInsensitive)`): tabla para español.
- `URL` mínima: esquema, host, ruta, última componente, extensión.
- Formato ISO 8601 y fechas largas en español con los nombres de meses que ya
  usa la app.
- `UUID` sobre el generador aleatorio de la stdlib.

Fuera a propósito: `FileManager`, `URLSession`, `Process`, `FileHandle`,
`DispatchQueue` (ya eran puertos o cosa del host), `DateFormatter`, `Locale`,
`NSString`, ICU.

## Consecuencias

- El CI añade una comprobación: ningún fichero bajo esos targets contiene
  `import Foundation`. El job `wasi` ya compila el núcleo a wasm; ahora además
  mide que la sonda y los plugins quedan por debajo de 1 MB.
- `Log` del motor deja de usar `DateFormatter` y `FileHandle`: la escritura a
  fichero pasa a ser un puerto que inyecta el host.
- Los puertos que hoy reciben `URL` (`RecordingSource`, `Sink`,
  `TranscriptionBackend`, `OKFFolder`) pasan a recibir la `URL` de
  EscribaFoundation; los hosts convierten en la frontera.
- Portar es trabajo mecánico pero amplio: Core tiene 16 ficheros con
  Foundation; Notion 11; OKF 4; Engine 3. Se hace por targets, con la suite de
  tests delante, en este orden: EscribaFoundation con tests propios → Core →
  Engine → OKF (y medir el plugin) → Notion → OpenAI → PluginKit.
- Se asume mantener la copia: no se actualiza sola. A cambio el núcleo deja
  de depender de que swift-foundation madure en WASI.

## Alternativas descartadas

- **`FoundationEssentials` solo.** Medido: no quita ICU en el SDK wasm actual.
- **Plugins en otro lenguaje** (AssemblyScript, Rust `no_std`). Resuelve el
  tamaño, pero el contrato, los conectores de serie y el SDK de plugins dejarían
  de ser Swift y de compartir código con el núcleo.
- **Esperar a que el SDK wasm recorte ICU.** No hay fecha y el núcleo en
  Kubernetes lo necesita ya.

## Lo que el ADR no sabía cuando se escribió (medido después, 2026-10-06)

La tabla de arriba mide una llamada trivial. Con el plugin OKF real, bajo
WasmKit y con la instancia viva, `form` tarda 0,65 s y `publish` 2,3–3,6 s:
no es el arranque, es que **un intérprete ejecuta Foundation unas 60 veces
más lento que un JIT**. El mismo módulo bajo wasmtime da 1–2 ms y 7 ms, y
bajo JavaScriptCore 40 ms y 90 ms (`docs/spike-conectores-wasm.md`). Por
tanto `EscribaFoundation` resuelve tamaño y arranque, pero la velocidad por
llamada la decide el runtime: la recomendación del spike es wasmtime. Antes
de dar este ADR por cerrado hay que medir el plugin OKF sin Foundation bajo
los dos runtimes.

## Hándicaps que quedan aun siguiendo la recomendación (2026-10-06)

Con wasmtime como runtime, `EscribaFoundation` hecho y los plugins como
reactores, esto es lo que se resuelve y lo que no:

**Se resuelve**
- Velocidad: de segundos a milisegundos por llamada.
- El trap de zonas horarias y la caída al cerrar el puente WASI.

**Pendiente de trabajo, no de decisión**
- Los 59 MB por plugin solo bajan con `EscribaFoundation`, que es un
  refactor ancho (Core, Notion, OKF, Engine) sin empezar. Hasta entonces cada
  plugin pesa 50–60 MB y tarda 1,6 s en compilarse la primera vez.

**No se resuelve; se asume**
- **Reactores y la directiva interna de Swift.** Un módulo WASI *comando*
  tiene `_start`, corre de arriba abajo y termina: una instancia por llamada.
  Un *reactor* tiene `_initialize` y exporta funciones que el host llama
  muchas veces conservando memoria y estado. Los plugins son reactores para
  no pagar el arranque de Foundation en cada llamada (0,85 s bajo WasmKit).
  El precio: dentro de una exportación síncrona hay que ejecutar el código
  asíncrono del motor (`Sink`, `NotionClient`), y para drenar el ejecutor se
  usa `swift_task_donateThreadToGlobalExecutorUntil`, una función interna del
  runtime de Swift, sin documentar ni garantizar. Si cambia, los plugins
  dejan de compilar (no fallan en silencio). Quitarla tiene dos vías, ninguna
  gratis: duplicar el cliente de Notion en forma síncrona, o volver al modelo
  de comando. **Medido después**: con wasmtime el modelo de comando cuesta
  5–11 ms por llamada con Foundation entera (arrancarla, unos 4 ms), así que
  con ese runtime la directiva sobra.
- **Doble descripción de la pantalla.** El formulario declarativo del plugin
  y el editor nativo de SwiftUI describen lo mismo. Solo desaparece si los
  conectores de serie también pasan a ser plugins y se borra el editor
  nativo: decisión de producto, no técnica.
- **Dependencia en C.** `libwasmtime` (24 MB) firmada dentro de la app, un
  binario por plataforma, y una caché precompilada de 111 MB por plugin
  ligada a la versión de wasmtime. Rompe «solo Swift» en esa capa.
- **Compilar un plugin en Swift tarda un minuto** y exige el toolchain de
  swift.org con su SDK wasm. Ningún runtime lo cambia. Para plugins
  generados por un agente, Swift no es el lenguaje adecuado.
- **Plataforma inmadura.** Foundation en wasm tiene bordes afilados (el de
  las zonas horarias costó una hora, con un trap sin mensaje). Habrá más.
