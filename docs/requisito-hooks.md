# Requisito funcional: hooks del usuario

Estado: **propuesto por Rubén el 2026-10-06**, pendiente de un spike con los
criterios de salida de abajo. Si se cumplen, se implementa; si no, se
documenta por qué y se cierra.

**Decisión de runtime (Rubén, 2026-10-06)**: los hooks se escriben en
**JavaScript** y los ejecuta **JavaScriptCore**, el motor del sistema. Va
detrás de un **puerto con adaptadores**, para poder cambiar JavaScriptCore por
un runtime de WebAssembly cuando compense, sin tocar el motor, el contrato ni
la interfaz.

## Qué tiene que poder hacer

El usuario cambia cómo trabaja Escriba sin tocar su código: en puntos fijos
del recorrido de una nota, la app llama a **hooks** que el propio usuario
escribe en un fichero `.js` y ejecuta dentro de la app. Cada hook recibe lo
que ha pasado y devuelve una **decisión**; la app la aplica. Es
metaprogramación: una configuración absoluta de la app sin tener que añadir un
ajuste por cada caso.

## Los tres puntos

| Evento | Cuándo | Qué recibe | Qué puede decidir |
|---|---|---|---|
| `audio-llegado` | La grabación está asentada y antes de transcribirla | Clave, origen (carpeta o bandeja), nombre, fecha, duración, opciones previstas (STT, LLM, idioma, hablantes) | Saltarla; elegir STT y LLM; idioma; detectar hablantes y cuántos; renombrarla |
| `transcripcion-terminada` | Antes de guardar la versión y de resumir | Lo anterior + la transcripción (segmentos, hablantes, tiempos) | Corregir el texto (glosario, nombres); renombrar hablantes; resumir o no, con qué LLM y con qué prompt |
| `resumen-terminado` | Antes de guardar y publicar | Lo anterior + el resumen (título, resumen, etiquetas) | Retocar título, resumen y etiquetas; a qué conectores se publica y a cuáles no |

- **N hooks por evento**, en el orden que elija el usuario, cada uno con su
  interruptor. La salida de uno es la entrada del siguiente.
- Se gestionan como los conectores: sección propia en la barra lateral, lista
  con editor (fichero `.js`, evento, orden, interruptor) y una prueba con una
  grabación de ejemplo que enseña la decisión antes de activarlo.
- La decisión de un hook **manda sobre todo lo anterior**, incluida la elección
  por grabación de STT y LLM (`ResolverRouting`).
- La respuesta es **parcial**: solo trae lo que cambia; lo que no viene se deja
  como estaba.

## Contrato: JSON, igual para cualquier runtime

El contrato es el mismo lo ejecute quien lo ejecute: un **evento en JSON**
entra y una **decisión en JSON** sale. Es lo que permite cambiar de runtime.

- El JSON lleva `"version": 1`. Un cambio incompatible sube la versión y la app
  sigue aceptando la anterior.
- **En JavaScript**: el fichero define una función por evento que recibe el
  evento como objeto y devuelve la decisión como objeto. El adaptador hace
  `JSON.parse` a la entrada y `JSON.stringify` a la salida, así que el hook
  nunca ve tipos de Swift.

  ```js
  function transcripcionTerminada(evento) {
    const glosario = { "escrivá": "Escriba", "zétesis": "Zetesis" }
    return {
      segmentos: evento.segmentos.map(s => ({
        ...s,
        texto: Object.entries(glosario).reduce((t, [mal, bien]) => t.replaceAll(mal, bien), s.texto),
      })),
    }
  }
  ```

- **En WebAssembly**, cuando llegue: el mismo JSON por stdin y la decisión por
  stdout de un módulo WASI, con un kit en Swift sin Foundation para que el
  módulo pese poco (`docs/exploracion-plugins-wasm.md`).
- Se publican los tipos del evento y de la decisión como `escriba-hooks.d.ts`
  (para que el editor del usuario autocomplete) y dos o tres hooks de ejemplo.
- Las palabras con sus tiempos van en el evento de `transcripcion-terminada`:
  medido, `JSON.parse` de 3 MB tarda unos 6 ms en JavaScriptCore.

## Arquitectura: puerto y adaptadores

- **Puerto `Hook` en `EscribaEngine`**, struct de funciones como `Summarizer` o
  `TranscriptionBackend`: recibe el evento ya codificado y devuelve la
  decisión, con errores tipados (`HookError`: no responde a tiempo, salida
  inválida, excepción). El `Pipeline` lo llama en los tres puntos y no sabe
  qué runtime hay detrás.
- **El contrato vive en `EscribaCore`**: tipos del evento y de la decisión,
  codificar y decodificar, y aplicar una decisión parcial sobre el estado de la
  nota. Todo función pura, con tests, portable a Linux y WASI.
- **Adaptador `EscribaHooksJSC`** (macOS): un `JSContext` por hook, sin nada
  expuesto salvo `log`; tiempo límite por llamada; el contexto se reutiliza
  entre llamadas del mismo hook.
- **Adaptador wasm, más adelante**: un `EscribaHooksWasm` con WasmKit o
  wasmtime que implementa el mismo puerto. Cambiar de runtime es cambiar qué
  adaptador construye el host; el motor, el contrato y la interfaz no se
  tocan. Es también el camino para hooks en un pod de Linux, donde no hay
  JavaScriptCore.
- **La app no compila nada ni lanza procesos**: el usuario elige un `.js` y la
  app lo copia a `~/Library/Application Support/escriba/hooks`, como los
  conectores guardan su configuración.

## Seguridad y fallos

- **Sandbox por construcción**: un `JSContext` no trae red, ni disco, ni
  temporizadores, ni `fetch`. El hook solo ve el evento y `log`. Un hook decide
  y la app ejecuta, nunca al revés.
- **Tiempo límite por llamada**: JavaScriptCore no lo ofrece en su API pública;
  sí con `JSContextGroupSetExecutionTimeLimit`, la función que usa WebKit, que
  se carga con `dlsym`. Probado el 2026-10-06 en macOS 26: un bucle infinito
  con límite de 200 ms se corta a los 211 ms con «JavaScript execution
  terminated», y el mismo contexto sigue respondiendo después en menos de 1 ms.
  Es API privada: si un día desaparece, el adaptador lo detecta al arrancar y
  desactiva los hooks con un aviso, en vez de ejecutarlos sin límite.
- **Memoria**: JavaScriptCore no tiene límite de memoria por contexto. Se
  asume para la primera versión; el tiempo límite acota la mayoría de los
  desbordes.
- **Un hook que falla no tumba la nota**: se anota en el log y en la
  biblioteca, y la nota sigue con la decisión que había antes de ese hook
  (igual que `forgiving(_:)` con los conectores).

## Criterios de salida del spike

1. El adaptador de JavaScriptCore ejecuta un hook `.js` detrás del puerto
   `Hook`, con el contrato en `EscribaCore` y un adaptador falso en los tests
   del motor.
2. Un hook de `transcripcion-terminada` que corrige un glosario cambia lo que
   llega a la biblioteca, al `.txt` y a Notion.
3. Latencia: menos de 50 ms por llamada en una nota de 45 minutos, con las
   palabras incluidas.
4. Un hook en bucle infinito se corta al vencer el tiempo límite y la nota
   sigue.
5. Un hook que devuelve algo que no casa con el contrato, o que lanza una
   excepción, deja la nota con la decisión anterior y el fallo a la vista.
6. Cambiar de adaptador es cambiar una línea en el host: se demuestra con el
   adaptador falso de los tests.

## Fuera de alcance de la primera versión

- Red desde los hooks y hooks que llamen a un LLM.
- Módulos e `import` entre ficheros: un hook es un fichero.
- Hooks en las acciones a mano (reprocesar, resumir, publicar).
- El adaptador de WebAssembly.

## Preguntas abiertas

- ¿Puede un hook de `audio-llegado` descartar una grabación para siempre, o
  solo saltarla esta vez?
- ¿Se le da al hook acceso de solo lectura al audio (por ejemplo para medir
  silencios)?
- ¿Permisos por hook (un dominio de red concreto, una carpeta) en una versión
  posterior?
- ¿Los hooks se ejecutan también al reprocesar o al resumir a mano?
- ¿TypeScript? JavaScriptCore solo ejecuta JavaScript; con el `.d.ts` el
  usuario puede escribir en TypeScript y compilar por su cuenta.
