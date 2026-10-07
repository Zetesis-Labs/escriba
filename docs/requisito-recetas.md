# Requisito funcional: recetas

Estado: **propuesto por Rubén el 2026-10-06**, en construcción desde el
2026-10-07 por la fase 1 (la memoria vive en la biblioteca, ver `CLAUDE.md`). El
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
  (la compilación da el grafo de imports) y se importa descomprimiéndola en el
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
  JavaScript. Vive en la app: no necesita proyecto ni entorno de desarrollo.
- **Manual**: TypeScript o JavaScript escrito a mano, por una persona o por un
  agente, en el proyecto de recetas (RF-18). No tiene formulario.
- «Convertir en manual» copia la receta generada al proyecto como TypeScript
  (si aún no hay proyecto, pregunta dónde crearlo) y desde ahí es manual.
  «Volver a generada» descarta la manual, con confirmación.
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
  proyecto, en **TypeScript o JavaScript**. Solo se importan ficheros del
  proyecto: un import de un paquete de npm es un error de compilación.
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
- **Contrato v0, el de la fase 2** (2026-10-07), en `recetas/escriba-recetas.d.ts`:
  un subconjunto de esta tabla. `escriba.transcribir(audio)` no admite opciones
  todavía: usa las de la carpeta y su STT. `nota.resumir()` usa el LLM de la
  carpeta y, mientras exista el ajuste global «Resumir» (hasta la fase 3), no
  llama a ningún modelo si está apagado y la traza lo dice. `nota.guardar()`
  escribe el `.txt` (la biblioteca ya tiene la transcripción y el resumen) y es
  obligatorio: una receta que termina sin guardar deja la nota fallida.
  `escriba.conector(clave).publicar(nota)` publica con la configuración actual
  del conector hasta la fase 5. Los errores de las capacidades llegan con
  `codigo` (`no-disponible` o `fallo`); si la receta no los recoge, salen como el
  mismo error de Swift, así que una nota con el motor caído espera igual que sin
  receta.

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

### RF-15. Prueba antes de activar

En la sección de recetas, «Probar con…» ejecuta la receta sobre una grabación
de la biblioteca **sin publicar** (los conectores registran lo que habrían
mandado) y enseña la traza, los datos y las cargas de cada conector.

### RF-16. Entorno de desarrollo dentro de la app: Monaco y esbuild

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
- **Por verificar en la fase**: que los *web workers* de Monaco y
  `esbuild.wasm` carguen con un esquema de URL propio de la app en vez de
  `file://`; y compilar con el editor cerrado, cuando edita un agente, con
  esbuild en una vista web oculta o en JavaScriptCore si admite WebAssembly.
  Sin el editor no hay servicio de TypeScript, así que ese informe trae
  sintaxis e imports; si el servicio se puede cargar en la misma vista oculta,
  también tipos.
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

- **Es una carpeta normal que elige el usuario.** La primera vez que crea una
  receta propia, la app pregunta dónde guardar el proyecto, con una carpeta
  sugerida, y lo crea desde la plantilla: `escriba-recetas.d.ts`,
  `tsconfig.json`, `.gitignore`, y un `AGENTS.md` y un `CLAUDE.md` que explican
  el contrato para que cualquier agente sepa programarlo. La app mantiene esos
  ficheros; el resto es del usuario.
- **La carpeta manda.** Se edita con Monaco dentro de la app (RF-16), con un
  agente o con el editor del usuario. La app la vigila: cuando cambia un
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
  que se arregle (Rubén, 2026-10-07): la app lo avisa en la lista de recetas,
  en Monaco y en `.escriba/estado.json`, y la traza de cada nota dice con qué
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
2. **Runtime y receta por defecto.** Adaptador de JavaScriptCore que carga
   paquetes, contrato, tiempo límite, traza; la receta por defecto, escrita en
   TypeScript y compilada dentro de la app, procesa igual que hoy (paridad
   comprobada con grabaciones reales).
3. **N recetas y enrutado.** Lista como los resolutores, generadas y manuales,
   receta por carpeta y en la flecha de grabar e importar, «Personalizar»,
   migración de los ajustes por carpeta, «Probar con…», el proyecto de recetas
   en la carpeta del usuario, compilado con esbuild (RF-18), y el entorno de
   desarrollo descargable con Monaco (RF-16).
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
- **Escribir recetas a mano sin descargar nada**: la primera receta propia baja
  unos 40 MB de entorno de desarrollo (RF-16).
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
