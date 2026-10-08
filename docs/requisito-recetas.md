# Requisito funcional: recetas

Estado: **propuesto por Rubén el 2026-10-06**, en construcción desde el
2026-10-07: fases 1, 2, 3, 4 y 6 hechas, con la depuración (RF-14) y «Probar
con…» (RF-15); siguiente, la fase 5. El recorte de alcance del 2026-10-07 está
en cada requisito afectado. El
mismo día Rubén rediseñó cómo se escriben: un proyecto en una carpeta que elige
el usuario, que la app compila a paquetes (RF-4, RF-16, RF-18). Sustituye a
`docs/requisito-hooks.md` (los tres eventos con N hooks pasan a ser recetas) y,
cuando se construya, al enrutado actual por carpeta y por grabación, a la
selección de conectores y a los editores de mapeo de Notion y OKF.

## La idea

Todo lo que pasa entre que entra un audio y acaba publicado lo decide una
**receta**: una función asíncrona en JavaScript que pide transcribir, espera
el resultado, decide con él, pregunta a los LLM lo que quiera con respuestas
estructuradas, guarda datos propios en la nota y elige a qué conectores
publica y con qué datos. El usuario tiene N recetas y elige cuál se aplica a
cada carpeta vigilada o a cada grabación. Una receta puede pasar la nota a
otra.

Las recetas viven en un **proyecto de código**, en una carpeta que elige el
usuario: una subcarpeta por receta y carpetas comunes que cualquier receta
importa. Lo edita una persona dentro de la app, un agente o el editor del
usuario, y la app lo compila a **paquetes**, que es lo único que ejecuta.

```
mis-recetas/                      el proyecto, donde elija el usuario
├── escriba-recetas.d.ts          tipos del contrato (los escribe la app)
├── tsconfig.json                 para el editor del usuario (lo escribe la app)
├── AGENTS.md, CLAUDE.md          el contrato explicado a cualquier agente (los escribe la app)
├── .escriba/estado.json          resultado de compilar, por fichero y línea (lo escribe la app)
├── comun/
│   ├── glosario.ts
│   └── categorias.ts
└── recetas/
    ├── general/
    │   └── receta.ts
    └── reuniones/
        ├── receta.ts
        └── plantillas.ts
```

```ts
// recetas/general/receta.ts
import { corregir } from "../../comun/glosario"
import { ESQUEMA, type Categoria } from "../../comun/categorias"

export const receta = { nombre: "General" }

export async function flujo(audio: Audio, escriba: Escriba) {
  if (audio.duracion < 10) return
  const nota = await escriba.transcribir(audio, { stt: "whisper", hablantes: { detectar: true } })
  nota.texto = corregir(nota.texto)
  const { categoria } = await escriba.preguntar<{ categoria: Categoria }>({ entrada: nota.texto.slice(0, 3000), esquema: ESQUEMA })
  nota.datos.categoria = categoria
  await nota.guardar()
  if (categoria === "reunion") return escriba.receta("reuniones")(nota)
  await nota.resumir({ llm: "apple" })
  await nota.guardar()
  await publicar(nota, escriba)
}

export async function publicar(nota: Nota, escriba: Escriba) {
  await escriba.conector("okf-ideas").publicar({
    documentos: [{ ruta: `ideas/${nota.fecha.slice(0, 10)}.md`, frontmatter: nota.datos, cuerpo: nota.resumen.texto }],
  })
}
```

## Requisitos funcionales

### RF-1. N recetas en una sola lista, una por defecto

- La app tiene **una lista de recetas** en su sección de la barra lateral, con
  los dos tipos juntos (Rubén, 2026-10-07): las **de formulario** (RF-3), que
  viven en la app, y las **de código**, las del proyecto de recetas (RF-18).
- Una es la **receta por defecto**, de cualquiera de los dos tipos: procesa lo
  que entra. La carpeta no sustituye a nada: sus recetas se suman a la lista y
  cualquiera se puede marcar por defecto.
- Las de formulario se añaden, duplican, renombran y quitan en la app; siempre
  queda al menos una. Las de código se gestionan en la carpeta.
- Si la receta por defecto no tiene paquete (una de código que nunca compiló o
  que ya no está en la carpeta), las notas esperan y la app lo dice: nunca se
  procesa con otra receta sin que el usuario la elija.
- Las recetas de código viven en el **proyecto de recetas** (RF-18): una receta
  es una subcarpeta de `recetas/` con su fichero de entrada, y el código
  compartido va en carpetas comunes.
- La **clave** de una receta es el nombre de su carpeta; el nombre que se ve
  en la app es `receta.nombre` y se cambia sin tocar la clave. Las
  redirecciones usan la clave, y la app la escribe en los tipos para que una
  clave mal escrita sea un error de tipos.
- Exportar e importar recetas sueltas: **descartado** (Rubén, 2026-10-07). El
  proyecto es una carpeta del usuario y se comparte como él quiera (git).

### RF-2. Qué receta procesa cada grabación

**La receta por defecto procesa todo lo que entra.** Elegir receta por carpeta
vigilada o al grabar e importar, y «Personalizar…» para una sola grabación,
**no se va a hacer** (Rubén, 2026-10-07): quien necesite repartir lo hace con
una receta de código por defecto que mira `audio` y pasa la grabación a otra
con `procesar` (RF-10).

**Reprocesar con una receta**:
la hoja de reprocesar pide la receta, con la por defecto marcada; si es de
formulario, sus parámetros se pueden retocar solo para esa vez (lo que hacía
«Reprocesar con otros criterios», como detectar hablantes en una nota
concreta). La receta hace su recorrido entero sobre la grabación: si los
criterios de transcripción no cambian, aprovecha la transcripción guardada, y
publica donde ella diga, regenerando las páginas que ya existían.

### RF-3. Recetas generadas y recetas manuales

- **Generada**: se edita con un formulario (STT, idioma, hablantes, resumir y
  con qué LLM y prompt, a qué conectores publicar) y la app escribe su
  JavaScript. Vive en la app: no necesita proyecto ni entorno de desarrollo.
- **Manual**: TypeScript o JavaScript escrito a mano, por una persona o por un
  agente, en el proyecto de recetas (RF-18). Si exporta `buildRecipeForm`,
  tiene un formulario que pinta la app a partir de su esquema (RF-4b).
- Convertir una receta generada en manual: **descartado** (Rubén, 2026-10-07).
- La app trae una receta generada, «Por defecto», que reproduce el
  comportamiento actual de Escriba. Todas las de formulario ejecutan el mismo
  código (`recetas/por-defecto/receta.ts`) con sus parámetros.

### RF-4. El contrato de una receta

El fichero de entrada de cada receta (`recetas/<clave>/receta.ts` o
`receta.js`) exporta:

| Nombre | Obligatorio | Qué es |
|---|---|---|
| `receta` | Sí | `{ nombre, datos? }`: `datos` es el esquema de Zod de los metadatos propios (RF-7) |
| `flujo(audio, escriba)` | Sí | Función asíncrona: todo el recorrido de una grabación |
| `buildRecipeForm(listas)` | No | Devuelve el esquema de Zod de sus parámetros (RF-4b) |
| `publicar(nota, escriba)` | No | Función asíncrona: publicar una nota ya procesada (RF-9) |

- Se escribe con **módulos normales**: `import` y `export` entre ficheros del
  proyecto, en **TypeScript o JavaScript**. Solo se importan ficheros del
  proyecto y **`zod`** (Rubén, 2026-10-08): cualquier otro paquete de npm es un
  error de compilación. Escriba baja Zod 4 de npm junto a esbuild (versión
  fijada y comprobada con su huella), esbuild resuelve `import { z } from "zod"`
  a esa copia y la app deja sus tipos en `.escriba/zod/` del proyecto, al que
  apunta `paths` en el `tsconfig.json` de la plantilla (con `skipLibCheck`,
  porque los tipos de Zod nombran `URL`, que no está en `es2022`).
- **La app compila y el motor ejecuta** (Rubén, 2026-10-07). JavaScriptCore no
  admite módulos en su API pública (verificado en las cabeceras de macOS 26),
  así que la app compila cada receta con **esbuild** a un **paquete**: un solo
  fichero de JavaScript con el código común que importa ya dentro. El motor
  solo carga paquetes; no lleva compilador ni cargador de módulos. Antes se
  pensó traducir fichero a fichero con el compilador de TypeScript y enlazarlos
  con un `require` propio.
- Cada receta se ejecuta en su propio contexto de JavaScript.
- Los tipos del contrato viven en un solo fichero, `escriba-recetas.d.ts`, que
  usan el editor de la app, el MCP (RF-17) y el editor propio del usuario. Un
  test lo compara con los tipos del contrato en Swift para que no se
  desincronicen.
- **Paquete de npm opcional**, `@zetesis/escriba-recipes`: los mismos tipos, un
  simulador para probar una receta sin la app y la misma compilación, para
  quien quiera CI o desarrollar fuera. Nunca hace falta, porque la app compila,
  y el usuario nunca publica nada en npm. Sin fase asignada.
- Se publica una galería de recetas de ejemplo.


### RF-4b. Parámetros de una receta de código

Decidido y hecho por Rubén el 2026-10-08: una receta de código declara sus
parámetros con Zod y la app pinta el formulario, como el de las recetas de
formulario.

- La receta exporta `buildRecipeForm(listas)` (el nombre lo eligió Rubén; vive
  en una sola constante, `recipeFormExport`). Recibe solo las listas de
  `escriba` (`stts`, `llms`, `conectores`, `recetas`), las mismas que verá la
  ejecución, y devuelve un `z.object`. Así las opciones salen de lo que hay
  configurado: `z.union(llms.map((llm) => z.literal(llm.clave).meta({ title: llm.nombre })))`.
- Los valores de serie son los `.default()` del script. Lo que el usuario
  cambia en la ficha se guarda por receta en el libro de recetas, **solo lo
  que difiere del script** (`recipeFormOverrides`), así que si el script
  cambia un valor de serie, cambia para quien no lo había tocado. «Volver a
  los valores del script» borra lo guardado.
- La app pinta el esquema de entrada (`~standard.jsonSchema.input()`):
  interruptores, desplegables (enumerados, uniones de literales con su
  `title`, enteros con mínimo y máximo cercanos), casillas
  (`z.array(z.enum(…))`), texto, números y grupos como secciones. Lo que no
  sabe pintar (`z.record`, `z.tuple`, listas libres, uniones de tipos
  distintos) lo dice con el camino del campo. `EscribaCore` decide todo esto
  (`recipeForm`, `recipeFormValues`, `recipeFormIssue`); JavaScriptCore solo
  calcula el esquema (`recipeFormSchema`), y la app lo guarda en caché por
  huella del paquete y listas.
- Al ejecutar, `escriba.parametros` sale de validar lo guardado con el mismo
  esquema en la misma máquina virtual, con los de serie rellenos y tipado con
  `Escriba<P>`. **Un valor guardado que ya no vale (un LLM quitado) hace fallar
  la ejecución nombrando el campo**, y la ficha lo marca: nunca se cambia por
  otro en silencio.
- «Reprocesar con…» prefija el formulario con lo guardado y lo que se cambie
  vale solo para esa vez y solo para la receta elegida: si ella pasa la
  grabación a otra con `procesar`, la otra usa lo suyo guardado.
- Un enumerado de una lista vacía (sin conectores) no lanza en Zod 4: sale un
  desplegable sin opciones, así que la plantilla recomienda
  `.nullable().default(null)`.

### RF-5. Lo que una receta puede pedir (`escriba` y `nota`)

| Capacidad | Qué hace |
|---|---|
| `audio` | Clave, origen (carpeta vigilada, bandeja, grabadora o importado), nombre, fecha, duración, `eleccion`. La hora llega aquí: la receta no la lee del reloj |
| `escriba.stts`, `escriba.llms` | Los resolutores configurados: clave, nombre, si es local, capacidad. Nunca las claves de API |
| `escriba.transcribir(audio, opciones)` | STT, idioma, detectar hablantes y cuántos. Devuelve la `nota` con segmentos, hablantes (con nombre si Personas los reconoce) y palabras con tiempos |
| `nota.resumir({ llm, prompt })` | El resumen de siempre (título, resumen, etiquetas), con el troceado y la reducción en cascada del motor |
| `escriba.preguntar({ llm, instrucciones, entrada, esquema })` | Respuesta estructurada de cualquier LLM disponible, con un esquema de Zod (RF-6); sin esquema, texto |
| `nota.datos` | El JSON de metadatos propios (RF-7) |
| `nota.guardar({ datos })` | Punto de control (RF-8); `datos` es opcional |
| `escriba.conector(clave).publicar(carga)` | Publicar en un conector con los datos que decide la receta (RF-9) |
| `escriba.receta(claveONombre).procesar(audio)` | Pasar la grabación a otra receta (RF-10) |
| `escriba.log(texto)` | Al log de la app y a la traza de la nota |

- Todas las capacidades que tardan devuelven una promesa: la receta hace
  `await` sin bloquear nada. Probado el 2026-10-06: un flujo en JavaScript
  espera a funciones asíncronas de Swift de 1,5 s, 1 s y 0,5 s, el hilo
  principal no se bloquea en ningún momento y el error de una de ellas llega a
  JavaScript como excepción que el `try/catch` de la receta recoge.
- Si una receta termina sin publicar ni guardar, la nota queda como **saltada
  por la receta**, a la vista.
- **Contrato v0, el de la fase 2** (2026-10-07), en `recetas/escriba-recetas.d.ts`:
  - `escriba.stts`, `escriba.llms` y `escriba.conectores` listan lo configurado,
    con su configuración en solo lectura: en los resolutores, si es local, el
    modelo y la URL base de los remotos (sin favorito desde el 2026-10-07); en
    los conectores, el tipo, si está activo y su destino (la base de Notion o
    la carpeta OKF). Nunca los tokens ni las claves de API, y la receta no
    cambia la configuración (Rubén, 2026-10-07). Publicar en un conector
    apagado es un error. Los locales tienen claves fijas, `whisper` y
    `apple`; los remotos, su identificador. Todo se puede pedir por clave o
    por nombre, sin distinguir mayúsculas; un nombre que llevan varios pide la
    clave.
  - `escriba.transcribir(audio, { stt, idioma, hablantes })`: lo que no se
    elige va al local (Whisper, idioma automático, sin hablantes). `idioma`
    tiene tres estados: ausente (automático), `null` (automático) o un código. `hablantes: { detectar, cuantos }`. Un STT
    remoto con `detectar: true` es un error, nunca texto sin hablantes. La
    memoria distingue cada STT y criterios: repetir la misma petición no paga
    otra transcripción.
  - `nota.resumir({ llm, prompt })`: resume siempre; sin `llm`, con Apple
    Intelligence, y sin `prompt`, con el de serie. Límite hasta la
    fase 4: el resumen se recuerda por versión, no por LLM y prompt, así que si
    la versión ya tenía resumen se devuelve ese y la traza dice «recordado».
  - `nota.guardar()` da la nota por buena en la biblioteca (la transcripción y
    el resumen ya están guardados; el `.txt` se fue el 2026-10-07) y es
    obligatorio: una receta que termina sin guardar deja la nota fallida.
  - `escriba.conector(claveONombre).publicar(nota)` publica con la
    configuración actual del conector; qué datos van a cada columna o documento
    lo decide la receta en la fase 5.
  - Los errores de las capacidades llegan con `codigo` (`no-disponible` o
    `fallo`); si la receta no los recoge, salen como el mismo error de Swift,
    así que una nota con el motor caído espera igual que sin receta.

### RF-6. Preguntas a los LLM con respuesta estructurada

- **El esquema es de Zod** (Rubén, 2026-10-08): el mismo `z.object` da el tipo
  de TypeScript (`z.infer`, o la inferencia de `preguntar`), el JSON Schema que
  se manda al LLM y la validación de lo que vuelve. El preludio solo habla con
  la interfaz Standard Schema (`~standard.jsonSchema` y `~standard.validate`),
  así que nunca nombra a Zod.
- Del JSON Schema que exporta Zod, `EscribaCore` (`answerSchema`) acepta el
  subconjunto que traducen los dos tipos de LLM: objetos, textos, números,
  enteros, booleanos, listas (con mínimo y máximo), enumerados y literales,
  nulos, opcionales y descripciones. Ignora las restricciones que no traduce
  (`minimum`, `pattern`, `format`…), que Zod vuelve a comprobar a la vuelta, y
  rechaza con la ruta del campo lo que ningún LLM sabe responder: `z.record`,
  `z.tuple`, uniones de tipos distintos y esquemas recursivos. La traducción va
  en cada adaptador: `json_schema` limpio y en orden en la API compatible con
  OpenAI (estricto solo si todos los campos son obligatorios en todos los
  niveles; si el servicio no admite esquemas, repite pidiendo un objeto JSON
  con el esquema en las instrucciones) y `DynamicGenerationSchema` en
  FoundationModels, donde los campos que admiten nulo son opcionales y el motor
  rellena con `null` los que no lleguen. Probado de verdad el 2026-10-08 con
  Apple Intelligence y un esquema de reunión con objeto anidado: 6,1 s.
- Probado el 2026-10-06 con Apple Intelligence: un esquema con categoría
  cerrada, cliente opcional y lista de tareas, construido en tiempo de
  ejecución, devolvió
  `{"categoria": "tarea", "cliente": "Acme", "tareas": [...]}` en 1,8 s.
- La respuesta **se valida contra el esquema** (Zod, en el preludio) antes de
  dársela a la receta; si no casa, la receta recibe un error con cada campo que
  falla, nunca datos a medias.
- Un LLM no disponible llega con `codigo: "no-disponible"` y, si la receta no
  lo recoge, la nota **falla** con ese motivo (no espera): esperar volvería a
  ejecutar la receta en cada pasada contra un LLM caído.
- La misma pregunta (LLM, instrucciones, entrada y esquema) sobre la misma
  versión **se recuerda** y no se repite; «Probar con…» aprovecha lo recordado
  pero no guarda respuestas nuevas.
- **Sin troceado automático**: si la entrada no cabe en la capacidad del LLM
  (unos 3500 caracteres en Apple Intelligence), la receta recibe un error
  claro y decide (preguntar sobre el resumen o usar un LLM remoto).
- Sin `llm`, va al local (Apple Intelligence).

### RF-7. Metadatos propios de la nota

- Cada **versión** de la transcripción guarda un JSON `datos` (columna
  `transcript.data`, migración `v9-datos`), igual que su resumen: reprocesar
  produce un análisis nuevo y no mezcla el viejo. El orden de los campos se
  conserva (`DataValue` en `EscribaCore`, con su propio lector de JSON).
- `nota.datos` llega con los de la versión; `await nota.guardar({ datos })`, o
  cambiar `nota.datos` y llamar a `guardar()`, los guarda. Si no cambiaron, no
  se manda nada; `null` los quita. Son un objeto de hasta 100 KB.
- Si `receta.datos` es un esquema de Zod, se validan al guardar y lo que no
  casa no se guarda. Un `receta.datos` que no es un esquema hace que la receta
  no cargue. Un cambio de esquema no toca las notas ya guardadas.
- **Un solo esquema para todo**, ahora con Zod (Rubén, 2026-10-08, en vez del
  constructor propio que se propuso el 2026-10-07).
- La biblioteca **muestra los datos** en el detalle de la nota, en su orden,
  con listas, grupos y sí o no, y «Cómo se procesó» enseña los que guardó cada
  ejecución, también en las pruebas. La etiqueta de cada campo es su `title`
  de Zod (`.meta({ title })`); sin él, la clave tal cual, sin adivinar
  mayúsculas ni tildes (Rubén, 2026-10-08). Por eso al guardar se guarda con
  la versión el JSON Schema de `receta.datos` (`transcript.dataSchema`,
  migración `v10-esquema-de-datos`): las etiquetas siguen valiendo aunque la
  receta cambie después. Lo que es `null` o está vacío no ocupa fila. **Filtrar y buscar** (por datos y dentro
  de las transcripciones) queda fuera hasta que Rubén lo pida (2026-10-08).
  Leer los datos de otras notas desde una receta sigue abierto.
- `{{datos.<campo>}}` en las plantillas de los conectores **no se hace**: la
  fase 5 quita esas plantillas y la receta decide la carga.

### RF-8. Guardar a mitad del proceso

- **Lo caro se guarda solo**: al terminar `transcribir`, la transcripción ya
  está en la biblioteca como versión de esa grabación con esas opciones; lo
  mismo el resumen, cada respuesta de `preguntar` y cada publicación. La
  biblioteca muestra cada etapa en cuanto llega.
- **Lo que la receta cambia se guarda cuando la receta dice**:
  `await nota.guardar()` escribe el texto corregido, los hablantes renombrados
  y los datos en la biblioteca. No crea una versión nueva y, si nada cambió,
  no escribe nada; sí deja esa versión como la de la nota y anota qué receta
  la hizo, que es lo que dice el menú de versiones.
- **Cada reprocesado a mano es una versión nueva** (Rubén, 2026-10-08): una
  receta hace el recorrido entero, así que su resultado no pisa el de otra.
  Si ya hay una transcripción con los mismos criterios, se copia sin volver a
  transcribir; el resumen, las preguntas y los datos se rehacen. Lo automático
  (una nota que entra, un reintento tras un cierre) sigue reutilizando la
  versión que hay. Si una receta pasa la nota a otra que transcribe con otros
  criterios, los datos que ya guardó la ejecución van también a la versión
  que acaba guardando.
- Guardar no publica. Publicar a mitad y otra vez al final duplica las
  peticiones a Notion (cientos en una nota larga); la receta por defecto
  publica una sola vez, al final.

### RF-9. Los conectores los decide la receta

- **El conector se queda en Swift con lo difícil**: la credencial (que
  JavaScript nunca ve), el destino (base de Notion, carpeta OKF), convertir
  cada valor al tipo de su columna, el texto con datos a bloques, la
  paginación, los reintentos con 429, regenerar la misma página y el rastro de
  publicación por conector.
- **La receta decide** a qué conectores publica, cuándo y con qué carga:
  Notion recibe `{ titulo, propiedades, cuerpo }`; OKF recibe
  `{ documentos: [{ ruta, frontmatter, cuerpo }] }`.
- La pantalla de un conector se queda en **nombre, credencial y destino**. Los
  editores de mapeo (columna a valor, plantillas del cuerpo, N documentos de
  OKF) desaparecen.
- Las recetas generadas publican con un **mapeo automático por tipo de
  columna**: título a la columna de título, fecha a la de fecha, etiquetas a la
  de selección múltiple, resumen a una de texto llamada «Resumen», la
  transcripción al cuerpo.
- **Acciones a mano**: al corregir hablantes, quitar el resumen o pulsar
  «Publicar», la app llama a `publicar(nota, escriba)` de la receta que
  procesó la nota; así la página se regenera con los datos nuevos sin repetir
  el análisis. Si la receta no exporta `publicar`, se avisa. Borrar una nota
  despublica por el rastro de publicación, sin pasar por la receta.

### RF-10. Una receta puede pasar la nota a otra

- `escriba.recetas` lista la lista entera (clave, nombre y tipo: `formulario`
  o `codigo`) y `escriba.receta(claveONombre).procesar(audio)` ejecuta el
  recorrido entero de otra receta, de cualquiera de los dos tipos, sobre la
  misma grabación (Rubén, 2026-10-07). Se busca como los conectores: por
  clave y, si no, por nombre sin distinguir mayúsculas.
- Comparten la nota: lo que la otra transcribe, resume y guarda es lo de esta
  grabación, así que su `guardar()` cuenta para las dos. `return` delante le
  pasa la grabación; `await` sin `return` la usa como un paso y sigue.
- Si la receta destino pide transcribir con lo mismo que ya se transcribió,
  recibe lo guardado al instante; con otros criterios sale una versión nueva.
- Cada receta llamada recibe sus propios `parametros` (los de su formulario,
  los guardados de su `buildRecipeForm` o `null` si es de código sin él) y
  corre en su propia máquina virtual.
- Límite de profundidad (4) y detección de ciclos (A llama a B y B a A): la
  llamada falla con un error que dice la cadena.
- Una receta que no existe es un error que la receta puede recoger; si no lo
  recoge, la nota falla, a la vista. La traza apunta cada paso con la receta
  que lo dio.

### RF-11. Repetir una receta es seguro

- Si la app se cierra a mitad, la receta se vuelve a ejecutar **desde el
  principio**: cada capacidad recuerda lo ya hecho para esa grabación con esas
  entradas (transcripción, resumen, respuestas de los LLM, publicaciones) y lo
  devuelve al instante, sin volver a pagarlo. Por eso la receta no lee el
  reloj ni el azar para decidir.
- Las respuestas de los LLM se guardan con la nota: repetir da la misma
  respuesta aunque el LLM no sea determinista.

### RF-12. Fallos

- Un fallo que afecta a todas las notas (red, clave, 429, 5xx, el modelo de
  Apple sin descargar) llega a la receta como error **«no disponible»**. Si la
  receta no lo recoge, la nota **espera** y se reintenta más tarde, como hoy.
- Un fallo de esa nota (413, 400, salida que no casa con el esquema) o una
  excepción no recogida dejan la nota **fallida**, con el mensaje y la línea de
  la receta.
- Una receta que nunca ha cargado (error de sintaxis, falta `flujo` o
  `receta`) no procesa nada: se avisa al guardarla, en la lista de recetas y en
  cada nota que espera por ella. Una que deja de cargar sigue con su último
  paquete bueno (RF-18).

### RF-13. Sandbox y tiempo límite

- Un contexto de JavaScriptCore no trae red, disco, temporizadores ni `fetch`:
  la receta solo ve el audio, la nota y las capacidades de `escriba`.
- **Tiempo límite de JavaScript: 10 s por tramo.** Un tramo es lo que la
  receta ejecuta sin parar entre dos `await`. Las esperas no cuentan:
  mientras un LLM o una transcripción trabajan, JavaScript está parado y el
  contador no corre. Protege contra un `while (true) {}` o una expresión
  regular catastrófica, que bloquearían para siempre el hilo de las recetas.
  Como referencia, parsear y responder un JSON de 3 MB tarda 6,5 ms.
- Se aplica con `JSContextGroupSetExecutionTimeLimit` (API privada, cargada con
  `dlsym`). Probado el 2026-10-06 con un límite de 200 ms, elegido solo para
  que la prueba fuese rápida: corta un bucle infinito a los 211 ms, el
  contexto sigue respondiendo, y un flujo con 3 s de esperas termina entero.
  Si la función desaparece en una versión de macOS, las recetas manuales se
  desactivan con un aviso.
- **Lo que tarda de verdad se controla en Swift, en cada capacidad**: los LLM
  y STT remotos fallan si el servidor pasa 300 s sin responder (como hoy) y
  eso llega a la receta como «no disponible»; la transcripción local y Apple
  Intelligence no tienen límite (una nota de 45 minutos tarda lo que tarda) y
  se paran con «Cancelar» desde la biblioteca. La receta entera no tiene
  plazo.
- **Tope de llamadas a LLM por nota: 50, ajustable.** Cubre el hueco que el
  tiempo límite no ve: una receta que llama a un LLM dentro de un bucle hace un
  `await` en cada vuelta y nunca agota su tramo. Al llegar al tope, la
  siguiente llamada falla y la nota lo muestra.
- Sin límite de memoria por contexto en la primera versión.
- **El corte usa las interrupciones por sondeo** de JavaScriptCore
  (`JSC_usePollingTraps`), que el adaptador activa antes de crear la primera
  máquina virtual. Con las de serie, por señal, un bucle dentro de código
  compilado por el JIT no se cortaba en el proceso de tests de swift-testing
  (verificado el 2026-10-07); por sondeo se corta igual en cualquier proceso,
  también tras un `await`.

### RF-14. Traza de cada nota

La nota guarda qué receta la procesó (y su huella), la cadena de recetas por
las que pasó, cada capacidad pedida con sus opciones, tiempos y errores, y lo
que la receta escribió en el log. La biblioteca lo enseña como «por qué se
procesó así». Al reprocesar, la hoja de reprocesado elige receta.

En la fase 2 la biblioteca guarda la última traza de cada grabación (receta,
huella, cada capacidad con su detalle, tiempo y error, el log y el error final)
y el detalle de la nota la enseña bajo el resumen.

**Depurar** (Rubén, 2026-10-07: ver qué se ejecuta y qué no es fundamental):

- **`console.log`, `info`, `warn`, `error` y `debug`** en la receta, además de
  `escriba.log`. Cada línea guarda su nivel, la receta que la escribió y los
  segundos desde que empezó la ejecución; un objeto se guarda como JSON
  legible y un `Error` como «nombre: mensaje».
- **Historial de ejecuciones**: cada ejecución queda guardada, venga del
  pipeline, de reprocesar o de «Probar con…», con la nota, la receta, las
  recetas por las que pasó (por clave), la huella, cuándo, cuánto tardó, el
  resultado (bien, falló o esperando: un motor caído deja la nota esperando y
  se reintenta) y la traza entera. Se conservan 30 días, y de las que esperan
  solo la última de cada nota y receta, para que un motor caído no llene el
  historial con un reintento cada pocos segundos. La nota sigue enseñando la
  última.
- **La ficha de cada receta** lista sus últimas ejecuciones, también cuando la
  llamó otra receta, filtrables por resultado; cada una se despliega con sus
  pasos, su log y su error.
- **Sección «Registro»** en la barra lateral: todas las ejecuciones de todas
  las recetas en vivo, filtrables por receta, resultado y texto, y en otra
  pestaña el log de la app (vigilancia, conectores, errores de fuera de las
  recetas), leyendo solo el final del fichero.
- Los errores al ejecutar dicen el fichero, la línea y la columna del
  TypeScript (source maps de esbuild guardados con el paquete) y «Probar con…»
  (RF-15). Todo esto, hecho el 2026-10-08.

### RF-15. Prueba antes de activar

En la sección de recetas, «Probar con…» ejecuta la receta sobre una grabación
de la biblioteca **sin publicar** (los conectores registran lo que habrían
mandado) y enseña la traza, los datos y las cargas de cada conector.

Hecho el 2026-10-08 en la ficha de cada receta: no crea versiones ni resúmenes
(aprovecha lo que ya hay en la biblioteca), no guarda ni publica, la traza dice
qué habría publicado en cada conector y queda en el historial como prueba, sin
cambiar la traza de la nota. Los datos y las cargas llegan con las fases 4 y 5.

### RF-16. Entorno de desarrollo dentro de la app: Monaco y esbuild

**esbuild está hecho** (2026-10-07): se descarga la primera vez que se elige
una carpeta de proyecto y compila al guardar. **Monaco queda aparcado por el
momento** (Rubén, 2026-10-07): el proyecto se edita con el editor del usuario
o con un agente, que leen los errores en `.escriba/estado.json`. Lo de abajo es
el diseño del editor si se retoma.

Decisiones de Rubén: el editor es **Monaco** (2026-10-06); se compila con
**esbuild** y el editor marca **errores de tipos** dentro de la app
(2026-10-07). Por eso Monaco y no CodeMirror 6, que pesa menos de 1 MB pero
sin el servicio de TypeScript solo marca sintaxis e imports.

| Pieza | Para qué | Tamaño |
|---|---|---|
| Monaco 0.57.0 | Editor, con el servicio de lenguaje de TypeScript: autocompletado de `escriba.` y `nota.`, errores de tipos y de sintaxis mientras se escribe, documentación al pasar el ratón y saltar a la definición, también entre ficheros | 25 MB con todos los lenguajes (medido el 2026-10-06); se recorta a JavaScript y TypeScript |
| esbuild 0.28.2 en WebAssembly | Compilar el proyecto a paquetes (RF-4) | 14 MB de `esbuild.wasm` y 53 KB de JavaScript |

- **Va en una vista web** (`WKWebView`), sin conexión.
- **Se descarga la primera vez que alguien crea una receta propia**, como el
  modelo de Whisper. Quien solo usa recetas generadas no lo baja y la app sigue
  pesando lo de hoy (15 MB).
- **Árbol del proyecto** a la izquierda (nativo, en SwiftUI) y pestañas en
  Monaco: crear, renombrar, mover y borrar ficheros y carpetas.
- **El texto vive en la carpeta del proyecto** (RF-18): Monaco lee y escribe
  ficheros de verdad y se refresca si los cambia un agente o el editor del
  usuario.
- **Al guardar**: un error de sintaxis o un import roto impide generar el
  paquete; un error de tipos se avisa pero no bloquea, como en TypeScript.
- **Compilar sin vista web, probado el 2026-10-07**: esbuild 0.28.2 en
  WebAssembly corre dentro de JavaScriptCore, sin vista web y con el editor
  cerrado, con `worker: false` y unos polyfills pequeños (`TextEncoder`,
  `TextDecoder`, `performance.now`, `crypto.getRandomValues`, `setTimeout`).
  Los ficheros llegan por un plugin que lee el proyecto y rechaza todo import
  que no sea del proyecto.

  | Prueba | Resultado |
  |---|---|
  | Compilar el `esbuild.wasm` (14 MB) y arrancar esbuild | 65 ms + 24 ms |
  | Receta de 4 ficheros en 2 carpetas, con imports relativos y tipos | 106 ms la primera vez, 37 ms después |
  | El paquete en un contexto limpio | Carga; `flujo` es una función |
  | Import roto, error de sintaxis, import de npm | `recetas/rota/receta.ts:1:25 no existe «../../comun/glosaro»`, `…:3:8 Expected "}"`, «solo se importan ficheros del proyecto», en 10-14 ms |
  | Memoria | Unos 125 MB más con esbuild cargado |

  Dos condiciones salen de la prueba. **El compilador necesita un hilo propio
  con su run loop**: en una cola de GCD, `WebAssembly.compile` no se resuelve
  nunca, porque JavaScriptCore entrega el resultado por el run loop del hilo
  que creó el contexto. **Se carga al compilar y se descarga tras un rato sin
  uso**, como el modelo de Whisper, por los 125 MB. Queda por verificar que
  los *web workers* de Monaco carguen con un esquema de URL propio de la app
  en vez de `file://`.
- **Firma**: hoy la app se firma sin el modo endurecido de macOS. Si se
  notariza para publicarla, hará falta el permiso
  `com.apple.security.cs.allow-jit` para que JavaScriptCore compile a código
  nativo.
- **Memoria**: no medida. Monaco y esbuild se cargan solo mientras hacen falta.

### RF-17. Acceso por MCP (propuesta, sin decidir)

Claude, Codex u otro agente se conectan por MCP para editar recetas y leer
resultados.

- **`escriba mcp`**, un subcomando del CLI que habla MCP por stdio con el SDK
  oficial de Swift (`modelcontextprotocol/swift-sdk`, 0.12.1). Lo arranca el
  cliente; la app no lanza procesos y no hace falta que esté abierta. Lee la
  biblioteca SQLite directamente (otro proceso puede leer mientras la app
  escribe) y escribe recetas en su carpeta, que la app recarga en caliente.
- **Herramientas**:

  | Herramienta | Qué hace |
  |---|---|
  | `proyecto_listar`, `fichero_leer` | El árbol del proyecto y el contenido de un fichero |
  | `receta_tipos` | `escriba-recetas.d.ts`, para que el agente sepa qué puede pedir |
  | `fichero_escribir`, `fichero_borrar` | Cambiar ficheros del proyecto; cada cambio se compila (RF-18) y devuelve sus errores |
  | `receta_probar` | Ejecutarla sobre una grabación sin publicar (RF-15) y devolver la traza, los datos y las cargas de cada conector |
  | `notas_buscar` | Por texto, fechas, receta o metadatos propios |
  | `nota_leer` | Transcripción con hablantes, resumen, datos, traza y dónde se publicó |

- **Sin MCP**, un agente también trabaja directamente en la carpeta: lee
  `escriba-recetas.d.ts` y `AGENTS.md`, guarda y lee el resultado en
  `.escriba/estado.json`.
- **Una receta escrita por MCP entra como borrador**: se puede probar, pero no
  procesa grabaciones hasta que una persona la activa en la app.
- **Nunca expone** credenciales ni huellas de voz.
- **Opcional y apagado por defecto**: lo que el agente lee viaja al
  proveedor de su modelo, en la nube. Un ajuste lo permite, con carpetas
  excluidas.
- **Orden**: leer resultados (`notas_buscar`, `nota_leer`) no depende de las
  recetas y se puede hacer antes (2 o 3 días); editar y probar recetas va
  después de la fase 3 (otros 2 o 3 días).

### RF-18. El proyecto de recetas

Rediseñado por Rubén el 2026-10-07.

- **Es una carpeta normal que elige el usuario.** La primera vez, la app
  pregunta dónde guardar el proyecto, con una carpeta sugerida, y si no tiene
  proyecto lo crea desde la plantilla: `escriba-recetas.d.ts`,
  `tsconfig.json`, `.gitignore`, una receta de ejemplo, y un `AGENTS.md` y un
  `CLAUDE.md` que explican el contrato para que cualquier agente sepa
  programarlo. **La plantilla se escribe solo al crear el proyecto** (Rubén,
  2026-10-07): después la carpeta es del usuario y la app solo escribe en
  `.escriba/`. Actualizar el contrato en un proyecto existente queda como
  acción explícita, sin construir todavía.
- **La carpeta manda.** Se edita con un agente o con el editor del usuario
  (Monaco dentro de la app, RF-16, está aparcado). La app la vigila: cuando cambia un
  fichero, compila las recetas afectadas, las valida (exportan `receta` y
  `flujo`, cargan sin errores) e instala su paquete.
- **El resultado de cada compilación**, con los errores por fichero y línea, se
  escribe en `.escriba/estado.json` dentro del proyecto, ignorado por git. Un
  agente guarda, lo lee y corrige sin pasar por la app.
- **Git y GitHub son cosa del usuario.** Para la app es una carpeta: si el
  usuario quiere, la versiona y la sube a GitHub, a un repo privado o a donde
  quiera, con sus herramientas, y un `git pull` en la carpeta se compila solo.
  La app no ejecuta `git` ni habla con GitHub. Si la carpeta es un repo, la app
  lee el commit actual de `.git` y lo guarda en la traza de cada nota (RF-14).
- **Estructura**: `recetas/<clave>/receta.ts` es una receta; cualquier otra
  carpeta (`comun/`, `lib/`, la que sea) es código compartido. Una receta
  puede tener ficheros propios en su carpeta.
- **Imports**: rutas relativas entre ficheros del proyecto. Sin paquetes de
  npm ni `node_modules`.
- **Un error en `comun/` aparece en las recetas que lo importan.** Una receta
  que deja de compilar o de validar **sigue con su último paquete bueno** hasta
  que se arregle (Rubén, 2026-10-07): la app lo avisa en la lista de recetas y
  en `.escriba/estado.json`, y la traza de cada nota dice con qué
  paquete se procesó.
- **Recarga en caliente**: una nota que ya está en marcha termina con el
  paquete con el que empezó; la traza guarda la huella del paquete y, si lo
  hay, el commit.
- El 2026-10-06 se probó la versión anterior, con el compilador de TypeScript
  dentro de JavaScriptCore: cinco ficheros, imports entre carpetas y
  redirección entre recetas funcionaron. Ese camino lo sustituye esbuild.

## Arquitectura

- **El contrato vive en `EscribaCore`**: tipos de `audio`, `nota`, opciones,
  esquema de respuestas, cargas de conector, validación y la regla de qué
  receta procesa cada grabación. Funciones puras, con tests, portables.
- **El motor ofrece capacidades** detrás de puertos (los de hoy:
  `TranscriptionBackend`, `Summarizer`, `Sink`, `LedgerPort`) más uno nuevo
  para preguntar con esquema, con la memoria de lo ya hecho. El ledger sigue
  siendo la fuente de verdad del pipeline y la biblioteca su espejo.
- **Puerto `RecipeRuntime`** en `EscribaEngine`: ejecutar una receta con unas
  capacidades. Adaptador **JavaScriptCore** en macOS (un hilo propio, nunca el
  principal; un contexto por receta) que carga el paquete de cada receta, un
  solo fichero sin módulos. El puerto permite cambiar
  JavaScriptCore por otro runtime (por ejemplo, un motor de JavaScript
  compilado a WebAssembly) sin tocar las recetas.
- **Puerto `RecipeBuilder`**: compilar el proyecto a paquetes y devolver los
  errores por fichero y línea. Adaptador esbuild en WebAssembly (RF-16).
- La app no lanza procesos: compila con esbuild en WebAssembly, dentro de la
  app.

## Migración

- La receta «Por defecto» de formulario nace de los ajustes y de los favoritos
  del 2026-10-07 (hecho). Los ajustes por carpeta y las elecciones de
  `elecciones.json` no se migran: no hay receta por carpeta ni por grabación.
- La configuración de cada conector (columnas, plantillas, documentos OKF) se
  traduce al `publicar` de la receta generada correspondiente: es solo datos y
  llama a las mismas funciones, así que no se pierde nada.
- Los editores de mapeo se borran solo después de verificar la publicación
  real en Notion con una receta, contra una base de verdad.

## Orden de construcción

Cada fase termina en la app, con tests, y la prueba Rubén.

1. **Capacidades con memoria, sin cambio visible.** El pipeline actual
   reescrito como capacidades que recuerdan lo hecho; misma conducta,
   mismos tests.
2. **Runtime y receta por defecto.** Adaptador de JavaScriptCore que carga
   paquetes, contrato, tiempo límite, traza; la receta por defecto, escrita en
   TypeScript y compilada dentro de la app, procesa igual que hoy (paridad
   comprobada con grabaciones reales).
3. **N recetas.** Hecho el 2026-10-07: una lista de formulario y de código con
   una por defecto, el proyecto en la carpeta del usuario compilado con
   esbuild (RF-18), reprocesar con una receta y «Probar con…» (RF-15).
   Descartado: receta por carpeta y al grabar, «Personalizar», convertir una
   generada en manual, exportar e importar recetas sueltas. Aparcado: Monaco.
4. **Preguntar y metadatos.** Hecho el 2026-10-08: `preguntar` con esquema de
   Zod en los dos tipos de LLM, respuestas recordadas por versión, `datos` por
   versión validados con `receta.datos`, la biblioteca los muestra. Filtrar y
   buscar, aplazado. Después, el mismo día: parámetros de las recetas de
   código con `buildRecipeForm` (RF-4b).
5. **Conectores decididos por la receta.** Cargas por tipo de conector,
   `publicar` exportado, acciones a mano, mapeo automático, migración de las
   configuraciones; verificación real en Notion y, después, borrar los
   editores.
6. **Redirección entre recetas**, con ciclos y profundidad. Adelantada a la
   fase 3 el 2026-10-07 (`procesar`, RF-10).
7. **Opcional**: Escriba escribe una receta con su propio LLM a partir de una
   descripción en castellano.

El MCP (RF-17), si se decide, va en paralelo: su lectura de resultados puede
ir antes de la fase 1, y la edición de recetas después de la 3.

Estimación: de 5 a 7 semanas en total, con el editor; la fase 1 y la 5 son
las grandes.

## Lo que se pierde, a sabiendas

- **El mapeo visual de columnas** para quien no programa. Se mitiga con el
  mapeo automático de las recetas generadas, la galería de ejemplos y la
  fase 7.
- **Escribir recetas a mano sin descargar nada**: elegir la carpeta de proyecto
  baja esbuild (14 MB).
- **Ejecutar fuera de macOS**: JavaScriptCore es del sistema. No es un
  objetivo (el escritorio fuera de Apple y el núcleo en Kubernetes están
  descartados).

## Preguntas abiertas

- La memoria recuerda la última versión con las mismas entradas aunque no sea
  la vigente. Si una pasada se interrumpe, Rubén reprocesa a mano con otros
  criterios y luego el demonio retoma la grabación, se publica la versión
  recordada y no la vigente. Se resuelve en la fase 5, cuando la receta decida
  qué publica.

- ¿Se procesan varias notas a la vez con recetas distintas, o se mantiene una
  a una como hoy?
- ¿Puede una receta de `flujo` descartar una grabación para siempre, o solo
  saltarla esta vez?
- ¿Se le da a la receta acceso de solo lectura al audio (para medir silencios)?
- ¿Paquetes de npm puros (sin APIs de Node) en una versión posterior?
