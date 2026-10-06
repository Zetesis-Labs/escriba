---
status: accepted
---

# El núcleo portable no usa Foundation: usa EscribaFoundation

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
