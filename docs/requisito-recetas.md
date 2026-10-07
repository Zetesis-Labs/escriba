# Requisito funcional: recetas

Estado: **propuesto por Rubén el 2026-10-06**, en construcción desde el
2026-10-07 por la fase 1 (la memoria vive en la biblioteca, ver `CLAUDE.md`). Sustituye a
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

Las recetas viven en un **proyecto de código**: una carpeta con una
subcarpeta por receta y carpetas comunes que cualquier receta importa.

```
recetas/                          el proyecto
├── escriba-recetas.d.ts          tipos del contrato (los escribe la app)
├── tsconfig.json                 para abrirlo también en VS Code (lo escribe la app)
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

### RF-1. N recetas, como los resolutores

- La app guarda **N recetas** y una **favorita**, con la misma forma que las
  listas de STT y de LLMs: sección propia en la barra lateral, añadir, quitar,
  duplicar, renombrar, marcar favorita.
- Las recetas viven en un **proyecto de recetas** (RF-18): una receta es una
  subcarpeta de `recetas/` con su fichero de entrada, y el código compartido
  va en carpetas comunes.
- La **clave** de una receta es el nombre de su carpeta; el nombre que se ve
  en la app es `receta.nombre` y se cambia sin tocar la clave. Las
  redirecciones usan la clave, y la app la escribe en los tipos para que una
  clave mal escrita sea un error de tipos.
- Una receta se exporta como su carpeta más los ficheros comunes que importa
  (la app conoce el grafo de imports) y se importa descomprimiéndola en el
  proyecto. Si ya existe una carpeta con esa clave, pide reemplazar o
  duplicar.

### RF-2. Qué receta procesa cada grabación

De más a menos concreto, como hoy `ResolverRouting` con STT y LLM:

1. La receta elegida para esa grabación al grabar o al añadir un audio (la
   flecha de «Grabar» y de «Añadir audio» ofrece recetas), guardada **antes**
   de que el fichero entre en la bandeja, como hoy `elecciones.json`.
2. La receta de su carpeta vigilada, o la de la bandeja.
3. La receta favorita.

«Personalizar…» en esa misma flecha abre los parámetros de la receta elegida
(si es generada) solo para esa grabación, sin crear una receta nueva. Llegan a
la receta en `audio.eleccion`.

### RF-3. Recetas generadas y recetas manuales

- **Generada**: se edita con un formulario (STT, idioma, hablantes, resumir y
  con qué LLM y prompt, a qué conectores publicar) y la app escribe su
  JavaScript. Editar el formulario reescribe el fichero.
- **Manual**: JavaScript escrito a mano. Su formulario se bloquea y lo dice.
- Una receta es manual cuando su fichero ya no coincide con lo que generaría
  su formulario (la app guarda los parámetros y la huella del fichero
  generado).
- «Convertir en manual» parte de lo generado; «Volver a generada» descarta el
  JavaScript a mano, con confirmación.
- La app trae una **receta por defecto** generada que reproduce el
  comportamiento actual de Escriba.

### RF-4. El contrato de una receta

El fichero de entrada de cada receta (`recetas/<clave>/receta.ts` o
`receta.js`) exporta:

| Nombre | Obligatorio | Qué es |
|---|---|---|
| `receta` | Sí | `{ nombre }` |
| `flujo(audio, escriba)` | Sí | Función asíncrona: todo el recorrido de una grabación |
| `publicar(nota, escriba)` | No | Función asíncrona: publicar una nota ya procesada (RF-9) |
| `datos` | No | Esquema de los metadatos propios de la receta (RF-7) |

- Se escribe con **módulos normales**: `import` y `export` entre ficheros del
  proyecto, en **JavaScript o TypeScript**. JavaScriptCore no admite módulos en
  su API pública (verificado en las cabeceras de macOS 26), así que la app
  traduce cada fichero con el compilador de TypeScript y los carga con un
  `require` propio que resuelve rutas relativas dentro del proyecto (RF-18).
- Cada receta se ejecuta en su propio contexto de JavaScript.
- Los tipos del contrato viven en un solo fichero, `escriba-recetas.d.ts`, que
  usan el editor de la app, el MCP (RF-17) y el editor propio del usuario. Un
  test lo compara con los tipos del contrato en Swift para que no se
  desincronicen.
- Se publica una galería de recetas de ejemplo.

### RF-5. Lo que una receta puede pedir (`escriba` y `nota`)

| Capacidad | Qué hace |
|---|---|
| `audio` | Clave, origen (carpeta vigilada, bandeja, grabadora o importado), nombre, fecha, duración, `eleccion`. La hora llega aquí: la receta no la lee del reloj |
| `escriba.stts`, `escriba.llms` | Los resolutores configurados: clave, nombre, si es local, capacidad, cuál es el favorito. Nunca las claves de API |
| `escriba.transcribir(audio, opciones)` | STT, idioma, detectar hablantes y cuántos. Devuelve la `nota` con segmentos, hablantes (con nombre si Personas los reconoce) y palabras con tiempos |
| `nota.resumir({ llm, prompt })` | El resumen de siempre (título, resumen, etiquetas), con el troceado y la reducción en cascada del motor |
| `escriba.preguntar({ llm, instrucciones, entrada, esquema })` | Respuesta estructurada de cualquier LLM disponible (RF-6) |
| `nota.datos` | El JSON de metadatos propios (RF-7) |
| `nota.guardar()` | Punto de control (RF-8) |
| `escriba.conector(clave).publicar(carga)` | Publicar en un conector con los datos que decide la receta (RF-9) |
| `escriba.receta(clave)(nota)` | Pasar la nota a otra receta (RF-10) |
| `escriba.log(texto)` | Al log de la app y a la traza de la nota |

- Todas las capacidades que tardan devuelven una promesa: la receta hace
  `await` sin bloquear nada. Probado el 2026-10-06: un flujo en JavaScript
  espera a funciones asíncronas de Swift de 1,5 s, 1 s y 0,5 s, el hilo
  principal no se bloquea en ningún momento y el error de una de ellas llega a
  JavaScript como excepción que el `try/catch` de la receta recoge.
- Si una receta termina sin publicar ni guardar, la nota queda como **saltada
  por la receta**, a la vista.

### RF-6. Preguntas a los LLM con respuesta estructurada

- `esquema` es un subconjunto de JSON Schema que traducen los dos tipos de
  LLM: objetos, textos, números, enteros, booleanos, listas, enumerados,
  obligatorios y descripciones. El contrato y la validación van en
  `EscribaCore`; la traducción, en cada adaptador (`json_schema` en la API
  compatible con OpenAI, `DynamicGenerationSchema` en FoundationModels).
- Probado el 2026-10-06 con Apple Intelligence: un esquema con categoría
  cerrada, cliente opcional y lista de tareas, construido en tiempo de
  ejecución, devolvió
  `{"categoria": "tarea", "cliente": "Acme", "tareas": [...]}` en 1,8 s.
- El host **valida la respuesta contra el esquema** antes de dársela a la
  receta; si no casa, la receta recibe un error, nunca datos a medias.
- **Sin troceado automático**: si la entrada no cabe en la capacidad del LLM
  (unos 3500 caracteres en Apple Intelligence), la receta recibe un error
  claro y decide (preguntar sobre el resumen o usar un LLM remoto).
- Sin `llm`, va al favorito.

### RF-7. Metadatos propios de la nota

- Cada **versión** de la transcripción guarda un JSON `datos`, igual que hoy
  guarda su resumen: reprocesar produce un análisis nuevo y no mezcla el
  viejo.
- Si la receta declara `datos`, se valida al guardar. Un cambio de esquema en
  la receta no toca las notas ya guardadas.
- La biblioteca **muestra los datos** de cada nota y permite **filtrar y buscar**
  por ellos (consultas JSON de SQLite); de paso cubre la búsqueda en
  transcripciones que estaba en las ideas sin dueño.
- Las plantillas de texto con datos (`{{titulo}}`, `{{fecha}}`…) ganan
  `{{datos.<campo>}}`.

### RF-8. Guardar a mitad del proceso

- **Lo caro se guarda solo**: al terminar `transcribir`, la transcripción ya
  está en la biblioteca como versión de esa grabación con esas opciones; lo
  mismo el resumen, cada respuesta de `preguntar` y cada publicación. La
  biblioteca muestra cada etapa en cuanto llega.
- **Lo que la receta cambia se guarda cuando la receta dice**:
  `await nota.guardar()` escribe el texto corregido, los hablantes renombrados
  y los datos en la biblioteca y en el `.txt`. No crea una versión nueva (solo
  reprocesar la crea) y, si nada cambió, no hace nada.
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

- `escriba.receta(clave)(nota)` llama a la otra receta como a una función:
  `return` delante le pasa la nota; `await` sin `return` la usa como un paso y
  sigue.
- La nota viaja ya transcrita: si la receta destino pide transcribir con las
  mismas opciones, recibe lo guardado al instante; con opciones distintas sale
  una versión nueva, como al reprocesar.
- Límite de profundidad y detección de ciclos (A llama a B y B a A): la
  cadena se corta con un aviso en la nota.
- Una clave que no existe es un fallo de la nota, a la vista.

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
- Una receta que no carga (error de sintaxis, falta `flujo` o `receta`) no
  procesa nada: se avisa al guardarla, en la lista de recetas y en cada nota
  que espera por ella.

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

### RF-14. Traza de cada nota

La nota guarda qué receta la procesó (y su huella), la cadena de recetas por
las que pasó, cada capacidad pedida con sus opciones, tiempos y errores, y lo
que la receta escribió en el log. La biblioteca lo enseña como «por qué se
procesó así». Al reprocesar, la hoja de reprocesado elige receta.

### RF-15. Prueba antes de activar

En la sección de recetas, «Probar con…» ejecuta la receta sobre una grabación
de la biblioteca **sin publicar** (los conectores registran lo que habrían
mandado) y enseña la traza, los datos y las cargas de cada conector.

### RF-16. Editor de recetas: Monaco

Decisión de Rubén el 2026-10-06: el editor de recetas manuales es **Monaco**,
el editor de VS Code, dentro de una vista web (`WKWebView`).

- **Va dentro de la app, sin conexión**: Monaco 0.57.0 (2026-09-24) ocupa
  25 MB en su versión mínima con todos los lenguajes, y se recorta a
  JavaScript y TypeScript. Por verificar en la fase: que sus *web workers*
  carguen sirviendo los ficheros con un esquema de URL propio de la app en vez
  de `file://`.
- **Ayudas al desarrollador** con el servicio de TypeScript de Monaco y
  `escriba-recetas.d.ts`: autocompletado de `escriba.` y `nota.`, errores de
  tipos y de sintaxis subrayados mientras se escribe, firma y documentación al
  pasar el ratón, y saltar a la definición, **también entre ficheros**: Monaco
  recibe todos los ficheros del proyecto, así que autocompleta lo que exporta
  `comun/` y marca un import roto.
- **Árbol del proyecto** a la izquierda (nativo, en SwiftUI) y pestañas en
  Monaco: crear, renombrar, mover y borrar ficheros y carpetas.
- **El texto vive en Swift**: la vista web solo edita; guardar, validar y
  traducir lo hace la app, por el mismo camino que una receta importada o
  escrita por MCP.
- **Validar y traducir sin editor**: el compilador de TypeScript, que es
  JavaScript puro, corre dentro de JavaScriptCore en su propio contexto.
  Medido el 2026-10-06 con TypeScript 5.9.3: cargarlo, 75 ms; errores de
  tipos de una receta, 15 ms; traducir TypeScript a JavaScript, 7,5 ms. Con
  él se validan también las recetas que llegan importadas o por MCP.
- **Al guardar**: un error de sintaxis impide guardar; un error de tipos se
  avisa pero no bloquea, como en TypeScript.
- **Firma**: hoy la app se firma sin el modo endurecido de macOS. Si se
  notariza para publicarla, hará falta el permiso
  `com.apple.security.cs.allow-jit` para que JavaScriptCore compile a código
  nativo.
- **Memoria**: no medida. Monaco y el compilador de TypeScript se cargan solo
  mientras el editor está abierto.

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
  | `fichero_escribir`, `fichero_borrar` | Cambiar ficheros del proyecto; cada cambio comprueba el proyecto entero (RF-18) y devuelve sus errores |
  | `receta_probar` | Ejecutarla sobre una grabación sin publicar (RF-15) y devolver la traza, los datos y las cargas de cada conector |
  | `notas_buscar` | Por texto, fechas, receta o metadatos propios |
  | `nota_leer` | Transcripción con hablantes, resumen, datos, traza y dónde se publicó |

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

- Es una **carpeta normal**: por defecto
  `~/Library/Application Support/escriba/recetas`, y el usuario puede elegir
  otra (por ejemplo, dentro de su carpeta de desarrollo) para versionarla con
  git o abrirla en VS Code. La app escribe y mantiene `escriba-recetas.d.ts` y
  `tsconfig.json`; el resto es del usuario.
- **Estructura**: `recetas/<clave>/receta.ts` es una receta; cualquier otra
  carpeta (`comun/`, `lib/`, la que sea) es código compartido. Una receta
  puede tener ficheros propios en su carpeta.
- **Imports**: rutas relativas entre ficheros del proyecto. Sin paquetes de
  npm ni `node_modules` en la primera versión.
- **Comprobación del proyecto entero** al guardar cualquier fichero: un error
  en `comun/` aparece en las recetas que lo importan. Un error de sintaxis
  desactiva las recetas afectadas hasta que se arregle (las demás siguen
  procesando); un error de tipos avisa pero no bloquea.
- **Recarga en caliente**: la app vigila la carpeta y vuelve a traducir solo
  lo que cambió. Una nota que ya está en marcha termina con el código con el
  que empezó; la traza guarda la huella del grafo de ficheros que usó.
- Las recetas generadas por el formulario también son carpetas del proyecto;
  editar a mano cualquiera de sus ficheros la convierte en manual.
- Probado el 2026-10-06 con un proyecto de cinco ficheros (dos recetas en
  subcarpetas y una carpeta común):

  | Prueba | Resultado |
  |---|---|
  | Comprobar los tipos del proyecto entero | 385 ms la primera vez, sin errores |
  | Traducir cada fichero para cargarlo | 18 ms |
  | La receta general importa de `comun/`, pregunta, y pasa la nota a la de reuniones, que también importa de `comun/` | Funciona, 0,5 ms sin contar las capacidades |
  | Renombrar mal un import | Error detectado entre ficheros en 8,5 ms |

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
  principal; un contexto por receta) con un cargador de módulos propio: cada
  fichero del proyecto traducido a CommonJS y un `require` que resuelve rutas
  relativas dentro del proyecto. El puerto permite cambiar
  JavaScriptCore por otro runtime (por ejemplo, un motor de JavaScript
  compilado a WebAssembly) sin tocar las recetas.
- La app no compila nada ni lanza procesos.

## Migración

- Cada combinación distinta de ajustes por carpeta de hoy (STT, LLM, idioma,
  hablantes, resumir) se convierte en una **receta generada** asignada a esas
  carpetas; la favorita sale de los favoritos actuales.
- La configuración de cada conector (columnas, plantillas, documentos OKF) se
  traduce al `publicar` de la receta generada correspondiente: es solo datos y
  llama a las mismas funciones, así que no se pierde nada.
- Las elecciones pendientes de `elecciones.json` pasan a «Personalizar».
- Los editores de mapeo se borran solo después de verificar la publicación
  real en Notion con una receta, contra una base de verdad.

## Orden de construcción

Cada fase termina en la app, con tests, y la prueba Rubén.

1. **Capacidades con memoria, sin cambio visible.** El pipeline actual
   reescrito como capacidades que recuerdan lo hecho; misma conducta,
   mismos tests.
2. **Runtime y receta por defecto.** Adaptador de JavaScriptCore, contrato,
   tiempo límite, traza; la receta por defecto procesa igual que hoy (paridad
   comprobada con grabaciones reales).
3. **N recetas y enrutado.** Lista como los resolutores, generadas y manuales,
   receta por carpeta y en la flecha de grabar e importar, «Personalizar»,
   migración de los ajustes por carpeta, «Probar con…», el proyecto de recetas
   con carpetas comunes (RF-18) y el editor Monaco con TypeScript (RF-16).
4. **Preguntar y metadatos.** `preguntar` con esquema en los dos tipos de LLM,
   `datos` por versión, la biblioteca los muestra y filtra.
5. **Conectores decididos por la receta.** Cargas por tipo de conector,
   `publicar` exportado, acciones a mano, mapeo automático, migración de las
   configuraciones; verificación real en Notion y, después, borrar los
   editores.
6. **Redirección entre recetas**, con ciclos y profundidad.
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
