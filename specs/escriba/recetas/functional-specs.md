# Recetas y sus ejecuciones

Análisis del 2026-10-13 sobre el código de `feat/filtros-biblioteca`, con las
decisiones que Rubén tomó ese día en conversación. Especificación funcional;
no describe la implementación. Sustituye como referencia vigente a
`docs/requisito-recetas.md`, que conserva el diseño original (octubre de 2026,
versión Swift) y ya no coincide con la app.

Estado: **decidido, sin construir.** Lo marcado como «hoy» es lo que hace la
app; lo marcado como «decidido» es lo que debe pasar a hacer. Destinos queda
**a reestudiar** (§10).

## 1. Resumen

Todo lo que ocurre entre que entra un audio y acaba publicado lo decide una
**receta**: una función asíncrona `flujo(audio, escriba)` que pide transcribir,
decide con el resultado, pregunta a los LLM, guarda datos en la nota, consulta
o escribe en el grafo de conocimiento y publica donde quiera. La app ejecuta
cada receta como un **trabajo** en segundo plano, lo recuerda todo por versión
para que repetir sea barato, y deja una traza por ejecución que se ve en
Trabajos y en la nota.

Esta iniciativa fija el planteamiento de las recetas sobre la app actual
(Escriba.app, ADR-0005) y cierra cinco decisiones: qué ve la receta del audio,
qué puede corregir, qué significa `guardar()`, cómo se reintenta un
reprocesado y cuánto espera un servicio caído. Una sexta, que nada se ejecute
fuera de la receta, queda decidida en principio y condicionada al modelo de
destinos, que está a reestudiar.

## 2. Actores

- **Rubén**, único usuario: escribe recetas (o las genera con un formulario),
  elige cuál procesa cada nota, corrige notas en la biblioteca y revisa
  Trabajos.
- **La receta**, código del proyecto del usuario o la «Por defecto» de serie,
  ejecutada en un proceso aislado sin red, disco ni procesos: solo ve lo que
  Escriba le da.
- **La cola de trabajos**, que ejecuta una receta a la vez (carril de
  inferencia) y hasta tres publicaciones o retiradas a la vez (carril de red),
  recupera lo interrumpido y reintenta lo que espera.
- **Servicios externos**: motores STT y LLM locales (Whisper, Apple
  Intelligence) o remotos compatibles con OpenAI, y las cuentas de Notion, OKF
  o proveedores declarados por el proyecto.

## 3. Objetivos

- Que una sola cosa decida qué pasa con cada nota: la receta. Nada se procesa,
  resume ni publica fuera de ella.
- Que repetir una receta nunca vuelva a pagar lo ya hecho ni pise lo que la
  persona corrigió.
- Que lo que la receta no hizo bien se vea: fallos con su paso, notas
  saltadas, servicios caídos esperando.

## 4. Puntos de entrada

- **Entra un audio** (grabadora, «Añadir audio…», carpeta vigilada, arrastrar):
  la nota queda pendiente y la cola la encola con su receta (la elegida al
  grabar o añadir, o la por defecto).
- **Reprocesar**, desde la nota o desde Trabajos: hoja con la receta (la de la
  nota marcada) y, si tiene formulario, sus valores solo para esa vez.
- **Probar con…**, desde la ficha de una receta: la ejecuta sobre una nota sin
  guardar versiones, resúmenes, datos ni publicaciones; deja la traza.
- **Corregir una nota** en la biblioteca (renombrar o fusionar hablantes,
  confirmar un borrador): guarda una versión de corrección. Hoy republica al
  momento; propuesto: no hace nada más (§6.4).
- **Trabajos**: cancelar, relanzar, ver pasos y errores.
- **Recetas**: proyecto en una carpeta del usuario, construido a `dist/`;
  formulario de cada receta; «Guardar como receta de formulario».

Hoy existen además tres acciones a mano desde la nota (resumir, publicar en
un destino, retirar una publicación). Propuesto, condicionado a destinos:
desaparecen (§6.4).

## 5. Recorridos

1. **Procesar una nota nueva.** Entra el audio → la cola encola «procesar» con
   la receta de la nota → cuando toca el carril de inferencia, la receta
   arranca y recibe `audio` → pide `transcribir` (versión nueva) → resume,
   pregunta, consulta el grafo, guarda datos → `guardar()` → publica → termina.
   La nota pasa por pendiente → procesando → terminada. Cada paso con su
   duración queda en la traza.
   - *Servicio caído*: la capacidad falla con `no-disponible`; si la receta no
     lo recoge, la nota vuelve a pendiente y el trabajo espera reintento (§6.6).
   - *Error de la nota* (respuesta que no casa con el esquema, excepción de la
     receta): la nota queda fallida con el mensaje; Trabajos permite relanzar.
   - *La receta vuelve sin `guardar()`*: la nota queda **saltada** (§6.3).
2. **Reprocesar a mano.** Rubén elige receta y valores → trabajo nuevo con
   «versión nueva» → la receta hace el recorrido entero; si los criterios de
   transcripción coinciden con una versión existente, copia la transcripción
   en la versión nueva sin transcribir; resumen, preguntas y datos se rehacen.
   Un reprocesado produce exactamente una versión, aunque se reintente (§6.5).
3. **Pasar la grabación a otra receta.** `escriba.receta(x).procesar(audio)`
   ejecuta el recorrido entero de la otra receta sobre la misma nota, con sus
   propios parámetros, dentro del mismo trabajo. Comparten la versión activa y
   los datos ya guardados pasan a la versión que acabe guardando.
4. **Corregir y volver a lanzar.** Rubén corrige hablantes o texto → versión
   de corrección, vigente, sin más efectos → cuando quiere, «Reprocesar» → la
   receta parte de la versión corregida: `transcribir` con los mismos criterios
   devuelve el texto y los hablantes corregidos, y `nota.datos` llega con lo
   que la persona dejó.
5. **Probar una receta.** Desde su ficha, sobre una nota de la biblioteca → no
   crea versiones ni publica, el grafo y las escrituras externas se deniegan,
   la traza dice qué habría publicado → queda en Trabajos como «Prueba de la
   receta X». Hoy no consulta la memoria: cada prueba vuelve a pagar resumen
   y preguntas (ver §10 y el anexo).
6. **Cancelar.** Desde la nota o Trabajos → la receta deja de poder pedir nada,
   su proceso termina y, si usaba un motor local, se corta → trabajo cancelado,
   nota fallida con «Proceso cancelado».

## 6. Reglas

### 6.1 Qué ve la receta del audio (decidido)

`audio` llega con sus metadatos antes de transcribir: clave, nombre, fecha,
**duración** y, si se pueden leer del fichero, tamaño y formato, y el origen (bandeja, carpeta vigilada,
grabadora o importado). Nunca la ruta del archivo ni el audio. Hoy solo llegan
clave, nombre y fecha, con origen vacío.

### 6.2 Qué puede corregir la receta (decidido)

La receta puede **renombrar hablantes** y **reemplazar el texto de un
segmento**; `guardar()` escribe esas correcciones en la versión activa, sin
crear otra, igual que las correcciones a mano. No puede sustituir el texto
plano completo: el texto deriva de los segmentos con sus tiempos y hablantes.
Hoy `nota.texto` y `nota.hablantes` son de solo lectura y `guardar()` solo
escribe `datos`.

### 6.3 `guardar()` es el punto de confirmación (decidido)

- Las versiones las crea solo `transcribir`: una por cada criterio distinto
  dentro de una ejecución, y una nueva al reprocesar a mano. `resumir`,
  `preguntar` y `guardar` escriben sobre esa versión activa, las veces que
  haga falta, sin crear otra.
- Lo caro se guarda en cuanto llega (transcripción, resumen, respuestas,
  publicaciones) y la biblioteca lo enseña.
- **La versión pasa a vigente cuando la receta llama a `guardar()`.** Hasta
  entonces existe pero no sustituye a la anterior. Hoy pasa a vigente al
  transcribir y `guardar()` solo añade `datos`.
- **Una receta que vuelve sin `guardar()` deja la nota saltada**, tanto si
  volvió antes de transcribir como si transcribió y decidió no quedarse con
  el resultado: la versión queda guardada pero no vigente, y la nota lo
  muestra con su traza. Saltar es asentar: la receta no lee reloj ni azar, así
  que reintentar daría lo mismo; «Reprocesar» sigue disponible. Hoy volver
  antes de transcribir deja la nota fallida y volver después la deja
  terminada.

### 6.4 Nada se ejecuta fuera de la receta (decidido en principio, condicionado a §10)

Rubén eligió «solo `flujo`» y, al ver lo que implica para lo publicado tras
una corrección, reabrió la premisa de los destinos (§10). Lo de abajo vale
mientras ese reestudio no lo cambie; lo marcado como propuesta no está
confirmado.

- Solo existe `flujo`. No hay segunda exportación (`publicar`) ni acciones a
  mano que llamen al LLM o al conector directamente.
- *Propuesta*: resumir a mano, «Publicar» en un destino y «Retirar»
  desaparecen de la nota; queda «Reprocesar». Borrar una nota sigue retirando
  lo publicado por su recibo, sin pasar por la receta.
- *Propuesta*: una corrección en la biblioteca guarda una versión y no dispara
  nada; la receta se ejecuta cuando Rubén pulsa «Reprocesar». Así una receta
  que no tiene en cuenta lo que ya había solo hace daño cuando se la lanza a
  propósito. Rubén señaló el riesgo contrario: sin destino que sepa
  regenerar una página, lo publicado queda desfasado hasta reprocesar.
- *Propuesta*: **lo que corrige la persona es la entrada de la receta, nunca
  algo que la receta pueda pisar.** La receta parte siempre de la versión vigente;
  `transcribir` con criterios iguales devuelve lo corregido, y `nota.datos`
  llega con los valores que la persona dejó. (Las correcciones manuales de
  registros del grafo ya están protegidas por revisión.)

### 6.5 Reintentos de un reprocesado (decidido)

Un reprocesado a mano que falla por un servicio caído se reintenta solo, y el
trabajo **recuerda la versión que creó en su primer intento**: los reintentos
la reutilizan y, si no llegó a crearla, la crean. Un reprocesado produce
exactamente una versión, caiga donde caiga. Hoy el reintento reutiliza
cualquier versión con esos criterios, también una antigua, y puede no crear
ninguna.

### 6.6 Esperar a un servicio caído (decidido)

Un `no-disponible` (servicio caído, modelo sin descargar, 429, 5xx) deja la
nota pendiente y el trabajo esperando reintento, con esperas que crecen desde
10 s hasta 5 min, **sin tope**, hasta que el servicio vuelve o alguien cancela.
Trabajos muestra la hora del siguiente intento. Un fallo propio de la nota no
se reintenta.

### 6.7 Reglas que se mantienen (hoy y decididas)

- La receta por defecto procesa lo que entra; elegir otra al grabar o añadir
  solo afecta a esa nota. Si la receta de una nota no está disponible (sin
  paquete, borrada del proyecto, el runtime no arranca), la nota espera y lo
  dice; nunca se procesa con otra.
- Una receta a la vez; publicaciones y retiradas hasta tres a la vez. Una nota
  no tiene dos trabajos activos. Un trabajo que pasa de dos horas falla.
- Cada capacidad recuerda lo hecho por versión: transcripción por criterios,
  resumen y respuestas por huella de la petición (LLM, instrucciones, entrada,
  esquema), publicaciones por recibo. Una versión manual nueva tiene su propia
  memoria.
- Reutilizar una transcripción con hablantes exige que la versión conserve
  sus huellas; si no, se vuelve a diarizar.
- Un STT remoto con `hablantes.detectar` es un error, nunca texto sin
  hablantes. Sin elección, transcribir y resumir usan el motor local.
- Un resumen vacío es un error. Si falla el resumen, la nota transcrita se
  conserva y el fallo se muestra.
- `preguntar` valida la respuesta con el esquema de Zod antes de dársela a la
  receta; sin troceado automático. Las preguntas hechas antes de transcribir
  no se recuerdan (no hay versión a la que anclarlas).
- `datos` se validan con `receta.datos` al guardar; un valor que ya no vale
  falla nombrando el campo. Los parámetros de la receta igual.
- Pasar la grabación a otra receta: ciclos y profundidad limitados, con un
  error que dice la cadena.
- La receta tiene 10 s de CPU entre capacidades y 512 MiB; no tiene plazo
  total salvo las dos horas del trabajo. Las esperas de STT y LLM no cuentan.
- La receta nunca ve credenciales, rutas de audio ni huellas de voz. Las
  escrituras arbitrarias por SDK o SurrealQL marcan la nota: un trabajo
  automático o un reintento no las repite; solo un reprocesado manual.
- Cada ejecución deja su traza (pasos, segundos, error, log de la receta) en
  el trabajo y en la nota. Las pruebas no cambian la traza de la nota.

## 7. Conceptos

- **Receta**: código (`flujo`) del proyecto o la «Por defecto»; una receta de
  formulario es un nombre y unos valores sobre cualquier receta con formulario.
- **Audio**: lo que la receta recibe de la grabación: identidad, nombre, fecha,
  duración, tamaño, formato y origen.
- **Nota**: la vista de la versión activa que la receta manipula: texto,
  hablantes, segmentos con palabras, resumen, datos. Expone `resumir`,
  `guardar`, `vincular` y, decidido, renombrar hablantes y corregir segmentos.
- **Versión**: resultado de una transcripción con unos criterios, con su
  resumen, datos y recibos. **Vigente** cuando la receta la confirma con
  `guardar()` o cuando es una corrección de la persona.
- **Trabajo**: una ejecución de la receta sobre una nota (ver la spec de
  Trabajos). Recuerda la versión que creó.
- **Estado de la nota**: pendiente, procesando, terminada, **saltada**
  (decidido, nuevo), fallida, descartada.
- **Memoria**: lo que cada capacidad guardó por versión para no repetirlo.
- **Traza**: pasos de una ejecución con duración, resultado o error, y el log
  de la receta.

## 8. Interfaz

Sin pantallas nuevas. Cambios:

- Decidido: estado «Saltada» en la lista y el detalle, con la traza que
  explica por qué.
- Propuesto (§6.4): la nota pierde «Resumir», «Publicar en…» y «Retirar»;
  conserva «Reprocesar» (con receta y valores), el menú de versiones y las
  correcciones.
- Trabajos y la ficha de la receta siguen igual.

## 9. Restricciones

- Nada de lo decidido está construido. Al construirlo cambian las reglas del
  producto de `CLAUDE.md` (guardar, acciones a mano, estados) y el contrato
  `escriba-recetas.d.ts`.
- Mientras no se reestudien los destinos (§10), `escriba.conector(clave)
  .publicar(nota)` sigue publicando con la configuración del destino.
- Fase 7 (Escriba escribe recetas con su LLM) sigue descartada; MCP (RF-17)
  sigue sin decidir; buscar en la biblioteca sigue aplazado.

## 10. Preguntas abiertas y supuestos

### Destinos: a reestudiar (Rubén, 2026-10-13)

Lo que hay: tres conceptos (cuenta, destino, receta) para dos
responsabilidades (quién soy; qué publico y cómo). El destino lleva la
«representación» (qué columna de Notion recibe qué, cómo se arma un documento
OKF) y se define en **dos sitios** que conviven: los destinos «gestionados»
de la pantalla del conector, con sus editores de mapeo, y los que declara
`src/conectores.ts` del proyecto con `createProgram(destinos, proveedores)`.
Al construir, la app conserva los gestionados y sustituye los del proyecto; la
receta ve ambos en `escriba.conectores` sin distinguirlos. La plantilla de un
proyecto nuevo escribe un destino por cuenta existente; sin cuentas, queda
`createProgram([])`. Toda la lógica de Notion y OKF (bloques, paginación,
reintentos, recibos) vive en `@escriba/conectores`.

Propuesta puesta sobre la mesa, no decidida: el destino desaparece como
entidad. Queda la **cuenta** en la app (credencial, alcance, y la base
compartida o la carpeta) y la **receta** publica con
`escriba.cuenta(x).publicar(carga)`, construyendo la carga con ayuda de
`@escriba/conectores`; el recibo se ancla a nota + cuenta + clave que da la
receta. Los editores de mapeo y el catálogo de destinos del proyecto se van;
`conectores.ts` queda para `defineProvider`. Coincide con el «propuesto, sin
decidir» del roadmap del 8 de octubre.

Objeción de Rubén que hay que resolver antes: regenerar una página tras una
corrección hoy solo necesita al destino y su recibo; sin destino, lo tiene que
hacer la receta al reprocesar (§6.4), y una receta que no cuenta con lo que ya
había puede pisarlo.

### Supuestos

- «Probar con…» debería aprovechar lo recordado sin guardar nada nuevo, como
  decía el requisito original; hoy no lo hace. No se ha decidido hoy.

- Los límites concretos (profundidad de recetas, llamadas a LLM por nota) los
  fija la implementación; el requisito original decía 4 niveles y 50 llamadas,
  el código hace 16 y ninguna. No se ha decidido cambiarlos.
- Se asume que una versión de corrección conserva los criterios de
  transcripción de su origen, para que `transcribir` la reconozca (§6.4). Hoy
  no los conserva.

## Anexo. Desviaciones entre documentación y código

Hechos comprobados el 2026-10-13 sobre `feat/filtros-biblioteca` (942df11).

| Dice | Hace | Dónde |
|---|---|---|
| `audio` lleva duración, origen y `eleccion` (`requisito-recetas.md:240`; `escriba-recetas.d.ts:1-12` declara `Origen` con `ruta`) | Solo clave, nombre y fecha; `origen: null` siempre | `apps/tauri/src/runtime/controller.ts:343-348` |
| `guardar()` escribe texto corregido y hablantes renombrados (`requisito-recetas.md:361-365`) | Solo `datos`; texto y hablantes son de solo lectura | `apps/tauri/src/runtime/worker.ts:125`; `controller.ts:545-566` |
| Terminar sin guardar deja la nota saltada (`requisito-recetas.md:256`) y, dos pantallas después, fallida (`:281`) | Sin transcribir: fallida. Transcribiendo sin guardar: terminada | `controller.ts:703`; `store/versions.rs:45` pone vigente al guardar la versión |
| Profundidad 4 al pasar entre recetas (`requisito-recetas.md:416`) | 16 | `controller.ts:308` |
| Tope de 50 llamadas a LLM por nota (`requisito-recetas.md:467`) | No existe | — |
| «Probar con…» aprovecha lo recordado (`requisito-recetas.md:320-322`) | En prueba no consulta la memoria: sin versión, calcula siempre | `runtime/memory.ts:20`; `controller.ts:514,592` |
| Reprocesar a mano crea versión nueva (`CLAUDE.md`, reglas del producto) | Solo en el primer intento; un reintento pasa a reutilizar | `src-tauri/src/jobs.rs:463-465` |
| Las acciones a mano llaman al `publicar` de la receta (`requisito-recetas.md:395-399`) | Resumir a mano lee los valores de la «Por defecto» de formulario y llama al LLM; corregir republica por el conector directamente | `controller.ts:750-806`; `src/library/operations.ts:11-21,33` |
| Una corrección reutiliza la transcripción (§6.4) | La versión de corrección se guarda sin `inputs`, así que `transcribir` no la reconoce y volvería a transcribir | `src/library/operations.ts:33` |
| Motor JavaScriptCore, esbuild, ledger de Swift, Monaco (`requisito-recetas.md:161-173, 445-477, 526-581, 656-677`; `roadmap.md:11-13`) | Bun aislado, `Bun.build`, cola en SurrealDB, CodeMirror (ADR-0005, ADR-0007) | `apps/tauri/runtime-host/README.md`; `docs/proyecto-recetas-tauri.md` |
| «Escritorio en Windows y Linux: SwiftUI en el Mac» (`roadmap.md:84`) | Swift solo adapta APIs de Apple; la app es Tauri | ADR-0005 |
| Dos fuentes de destinos sin distinguir en la receta (§10) | Gestionados de la UI + declarados en el proyecto | `src-tauri/src/catalog.rs:96-106`; `store/configuration.rs:69`; `src-tauri/src/project.rs:776` |

Lo que sí coincide y conviene no tocar: memoria por versión y huella de la
petición, recibos de publicación con reconciliación, marcador de efectos
externos inciertos, carriles y reintentos, traza por ejecución, aislamiento de
la receta, dependencias de ontologías y la base `escriba` de solo lectura.
