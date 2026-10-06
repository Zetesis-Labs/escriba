# Requisito funcional: hooks del usuario en WebAssembly

Estado: **propuesto por Rubén el 2026-10-06**, pendiente de un spike con los
criterios de salida de abajo. Si se cumplen, se implementa; si no, se
documenta por qué y se cierra.

## Resultado del spike de conectores como plugins (2026-10-06)

Medidas completas, hándicaps y recomendación de runtime en
`docs/spike-conectores-wasm.md`: con wasmtime, 1–7 ms por llamada y tiempo
límite por época, que es lo que piden estos hooks.

Hecho en la rama `feat/conectores-wasm` (commit `b2b2218`): Notion y OKF
compilan también como plugins WASI, la app los carga con WasmKit y publican de
punta a punta por dos llamadas al host; el editor del plugin OKF conserva todo
lo del nativo (N documentos, propiedades, plantillas con enlaces, vista previa)
gracias a un formulario declarativo. Medidas con Foundation: 59 MB por plugin,
4–5 s por comando, 850 ms/35 ms como reactor. Sin Foundation: 6,8 MB y 0,5 ms.
Conclusión: viable, y el peaje es Foundation, no wasm ni WasmKit. De ahí el
[ADR 0001](adr/0001-escriba-foundation.md): el núcleo deja Foundation. Los
hooks de este documento y los plugins comparten runtime, contrato y SDK, y el
objetivo de producto es que un MCP de Escriba permita a Claude generar e
instalar plugins en caliente.

## Qué tiene que poder hacer

El usuario cambia cómo trabaja Escriba sin tocar su código: en puntos fijos
del recorrido de una nota, la app llama a **hooks** que el propio usuario
escribe (en Swift o en cualquier lenguaje que compile a WebAssembly),
compilados a un `.wasm` y ejecutados dentro de la app. Cada hook recibe lo que
ha pasado y devuelve una **decisión**; la app la aplica. Es metaprogramación:
una configuración absoluta de la app sin tener que añadir un ajuste por cada
caso.

## Los tres puntos

| Evento | Cuándo | Qué recibe | Qué puede decidir |
|---|---|---|---|
| `audio-llegado` | La grabación está asentada y antes de transcribirla | Clave, origen (carpeta o bandeja), nombre, fecha, duración, opciones previstas (STT, LLM, idioma, hablantes) | Saltarla; elegir STT y LLM; idioma; detectar hablantes y cuántos; renombrarla |
| `transcripcion-terminada` | Antes de guardar la versión y de resumir | Lo anterior + la transcripción (segmentos, hablantes, tiempos) | Corregir el texto (glosario, nombres); renombrar hablantes; resumir o no, con qué LLM y con qué prompt |
| `resumen-terminado` | Antes de guardar y publicar | Lo anterior + el resumen (título, resumen, etiquetas) | Retocar título, resumen y etiquetas; a qué conectores se publica y a cuáles no |

- **N hooks por evento**, en el orden que elija el usuario, cada uno con su
  interruptor. La salida de uno es la entrada del siguiente.
- Se gestionan como los conectores: sección propia en la barra lateral, lista
  con editor (fichero `.wasm`, evento, orden, interruptor) y una prueba con
  una grabación de ejemplo que enseña la decisión antes de activarlo.
- La decisión de un hook **manda sobre todo lo anterior**, incluida la elección
  por grabación de STT y LLM (`ResolverRouting`).
- La respuesta es **parcial**: solo trae lo que cambia; lo que no viene se deja
  como estaba.

## Contrato

- El evento entra como **JSON por stdin** del módulo WASI y la decisión sale
  como **JSON por stdout**; stderr va al log de la app. Sin ABI propia ni
  memoria compartida, así que vale cualquier lenguaje (Swift, Rust, TinyGo,
  AssemblyScript…).
- El JSON lleva `"version": 1`. Un cambio incompatible sube la versión y la app
  sigue aceptando la anterior.
- Se publica un SDK en Swift (`EscribaHookKit`) **sin Foundation**, con los
  tipos del evento y de la decisión y un `Hook.run { evento in decisión }`. Sin
  Foundation el módulo se queda pequeño: la sonda wasm actual pesa 7 MB sin
  Foundation y el núcleo con Foundation ~45 MB por ICU.
- El component model (WIT) sería el contrato tipado ideal, pero Swift aún no
  tiene SDK wasip2; queda para cuando lo tenga.

## Seguridad y fallos

- **Sandbox de WASI**: sin red y sin disco, salvo lo que la app conceda.
  Un hook decide y la app ejecuta, nunca al revés.
- **Tiempo límite y memoria** por llamada: un hook colgado o que se desboca se
  corta y no para el pipeline.
- **Un hook que falla no tumba la nota**: se anota en el log y en la
  biblioteca, y la nota sigue con la decisión que había antes de ese hook
  (igual que `forgiving(_:)` con los conectores).

## Arquitectura

- Puerto `Hook` en `EscribaEngine` (struct de funciones, como `Summarizer` o
  `TranscriptionBackend`); el `Pipeline` lo llama en los tres puntos.
- Aplicar una decisión parcial sobre el estado de la nota es una función pura
  en `EscribaCore`, con tests.
- El runtime va en un target propio (`EscribaHooks`) con **WasmKit**, runtime
  de WebAssembly escrito en Swift y con WASI preview 1, sin dependencias C. Si
  se queda corto en velocidad, la alternativa es la C API de wasmtime.
- **La app no compila hooks**: nada del repo lanza procesos externos. El
  usuario compila con la toolchain de swift.org y su SDK wasm
  (`swift build --swift-sdk swift-6.4.0-RELEASE_wasm`) y elige el `.wasm`.

## Criterios de salida del spike

1. WasmKit, embebido en la app, ejecuta un hook Swift compilado a
   `wasm32-unknown-wasip1` pasándole el evento por stdin y leyendo la decisión
   por stdout.
2. Un hook de `transcripcion-terminada` que corrige un glosario cambia lo que
   llega a la biblioteca, al `.txt` y a Notion.
3. Tamaño: el hook mínimo con `EscribaHookKit` pesa menos de 10 MB.
4. Latencia: menos de 200 ms por llamada con el módulo ya cargado. Se mide
   también el tiempo de la primera carga.
5. Un hook en bucle infinito se corta al vencer el tiempo límite y la nota
   sigue. Si WasmKit no puede interrumpir la ejecución, se documenta y se
   evalúa wasmtime (epoch interruption).
6. Un hook que devuelve JSON inválido o termina con error deja la nota con la
   decisión anterior y el fallo a la vista.

## Fuera de alcance de la primera versión

- Red desde los hooks y hooks que llamen a un LLM.
- Compilar hooks desde la app.
- Hooks en las acciones a mano (reprocesar, resumir, publicar).

## Preguntas abiertas

- ¿Puede un hook de `audio-llegado` descartar una grabación para siempre, o
  solo saltarla esta vez?
- ¿Se le da al hook acceso de solo lectura al audio (por ejemplo para medir
  silencios)?
- ¿Permisos por hook (un dominio de red concreto, una carpeta) en una versión
  posterior?
- ¿Los hooks se ejecutan también al reprocesar o al resumir a mano?
