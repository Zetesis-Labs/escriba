# Requisito funcional: memoria de hablantes

Estado: **aprobado** (Rubén, 2026-09-22) y **en construcción** desde el
2026-10-08: el camino 1 entero, con las medidas del paso 2 abajo. Análisis y
plan; los criterios de salida están al final de cada paso. Traído al repo público el
2026-10-06; en la app la feature se llama **Personas**. Las opciones de motor,
con la dirección de computación local, están en
`docs/exploracion-transcripcion-diarizacion.md`.

**Prioridad (Rubén, 2026-10-06)**: dejar bien el **camino 1** (huellas propias,
por defecto en cada grabación). El **camino 2** (Sortformer con voces
inscritas, como postprocesado para precisar una grabación) es una opción
alternativa que solo se construye después y si el banco de pruebas lo
justifica.

## Qué tiene que poder hacer el usuario

1. Bautizar a un hablante una vez, en una grabación, como ya hace hoy.
2. Que en las siguientes grabaciones ese hablante aparezca **con su nombre**,
   marcado como reconocido.
3. Corregir siempre: deshacer un reconocimiento, renombrar, fusionar.
4. Que la app **nunca** afirme un nombre sin que se pueda ver que fue una
   suposición.

## Cómo funciona hoy la diarización

Dos trabajos independientes sobre el **mismo** audio, unidos por el reloj:

- **Transcribir**: WhisperKit escribe las palabras con su inicio y su fin
  (`wordTimestamps: true`).
- **Diarizar**: SpeakerKit parte el audio en tramos de voz, saca una huella de
  cada tramo, los agrupa por parecido y dice quién habla en cada intervalo. No
  ve ni una palabra.
- **Unir**: cada palabra hereda el hablante del tramo en el que cae; las
  palabras seguidas del mismo hablante forman un turno.

Dos detalles que importan y ya están en el código: el audio se carga **una
sola vez** en memoria y se le pasa el mismo array a los dos (si cada uno leyera
el fichero por su cuenta y uno recortara silencios, los relojes se
desplazarían); y sin tiempos por palabra las transcripciones diarizadas salen
vacías, porque el texto de cada tramo se reconstruye desde las palabras.

Unir por solape de tiempos **es el estándar**, no un apaño: Apple con
SpeechAnalyzer y FluidAudio lo hacen igual.

## Dónde se pierde precisión

- Los tiempos de Whisper son aproximados (décimas), así que la primera palabra
  tras un relevo puede caer del lado equivocado.
- Las fronteras de la diarización también lo son. Según el benchmark
  independiente de 2026 (arXiv 2509.26177), **el fallo dominante en todos los
  sistemas es perder habla en los bordes**, no confundir personas.
- Con habla superpuesta solo hay una etiqueta por instante: las
  interrupciones se atribuyen mal por definición.

Mitigaciones baratas para cuando escribamos nuestra propia unión: asignar por
**mayor solape** en vez de por el punto medio de la palabra, ignorar tramos de
voz muy cortos, y suavizar los cambios de una sola palabra.

## Las cuatro palancas de precisión, de más barata a más cara

1. **Decir cuántos hablan.** Ya está (ajuste por grabación y por carpeta). Evita
   el error más común, inventarse un tercero.
2. **No mezclar los canales.** Si el audio trae una pista por persona, la
   diarización sobra y el resultado es exacto. Hoy el código suma los canales a
   mono; está apuntado como pendiente en `CLAUDE.md`.
3. **Anclar con voces conocidas.** Es este requisito. Además de poner nombres
   sirve para corregir: dos grupos que casen con la misma huella se funden.
4. **Cambiar de modelo.** Ver más abajo: no regala nada y hay que medirlo.

## Datos reales (log de Rubén)

Distancia de coseno entre los centroides de dos hablantes distintos **dentro de
la misma grabación**:

```
2026-09-04  diarizacion: 2 hablantes; distancias 1-2: 0.794
2026-09-21  diarizacion: 2 hablantes; distancias 1-2: 0.763
2026-09-25  diarizacion: 2 hablantes; distancias 1-2: 0.775
2026-09-25  diarizacion: 2 hablantes; distancias 1-2: 0.671
2026-09-29  diarizacion: 4 hablantes; distancias 1-2: 0.710, 1-3: 0.668, 1-4: 0.389, 2-3: 0.618, 2-4: 0.783, 3-4: 0.758
2026-10-03  diarizacion: 2 hablantes; distancias 1-2: 0.821
2026-10-03  diarizacion: 4 hablantes; distancias 1-2: 0.703, 1-3: 0.836, 1-4: 0.554, 2-3: 0.757, 2-4: 0.604, 3-4: 0.637
2026-10-05  diarizacion: 2 hablantes; distancias 1-2: 0.546
```

Personas distintas quedan lejos, entre 0,55 y 0,84, con una excepción a 0,39
en la reunión de cuatro del 29-09: o son dos personas de voz parecida o es una
persona partida en dos grupos. Lo que **no** se sabe todavía es a qué
distancia queda una persona **de sí misma** en dos grabaciones distintas,
porque hoy las huellas se tiran al terminar. Eso es lo que mide el paso 2.

## Dos caminos, en dos capas

| | Camino 1: huellas propias | Camino 2: Sortformer con inscripción |
|---|---|---|
| Papel | Por defecto, en cada grabación | Opcional, después, para precisar una grabación |
| Cómo reconoce | Compara la huella de cada hablante con las de cada persona | El modelo recibe clips de voz de personas conocidas y las nombra al diarizar |
| Hablantes por grabación | Sin tope | Máximo 4, contando los inscritos |
| Personas que reconoce | Todas | Hasta 4 por grabación: las que propone el camino 1 |
| Memoria entre grabaciones | La guarda Escriba | Ninguna en el modelo; Escriba guarda los clips |
| Motor | El actual (SpeakerKit, pyannote Community-1) | FluidAudio |

## Camino 1 (prioridad): huellas propias, en tres pasos

### Paso 1: guardar las huellas

Persistir los centroides junto a la grabación (tabla propia en la biblioteca,
con la versión de transcripción que los generó). No cambia ningún
comportamiento y no hay umbral que acertar.

*Criterio de salida*: tras diarizar, las huellas quedan en la biblioteca y se
pueden leer.

### Paso 2: medir con grabaciones reales

Con tres o cuatro grabaciones ya diarizadas donde salga la misma persona,
calcular la distancia de cada uno consigo mismo y con los demás.

*Criterio de salida*: hay un umbral que separa «misma persona» de «otra» sin
solaparse. **Si no lo hay, la feature no se hace** y se dice.

**Medido el 2026-10-08** con `escriba hablantes` (vuelve a diarizar las 8
grabaciones con hablantes de la biblioteca, sobre una copia, con las mismas
opciones que la app) tomando como referencia a Rubén, bautizado en una nota:

- Rubén consigo mismo en otras seis grabaciones: 0,125 a 0,234, y un solo
  hablante por nota por debajo de 0,30.
- Personas distintas: lo más cercano a Rubén fuera de ese grupo queda a 0,374,
  y entre hablantes de una misma nota el mínimo es 0,389 (el resto, por encima
  de 0,42).
- **Umbral: 0,30**, en el hueco y con margen a los dos lados.

Muestras cortas de la voz de Rubén recortadas de esas grabaciones (para
«Registrar voz»): con 10 s la huella no sirve (más de 1 contra todo); con 20 s
se solapa con otras personas (0,28–0,42 frente a 0,37–0,49); con unos 30 s de
voz vuelve a separar (0,14–0,25 frente a 0,31 o más). Por eso la muestra
exige 30 s de voz y se pide hablar un minuto.

### Paso 3: encender el reconocimiento (Personas)

Al bautizar a alguien, su huella queda con el nombre. En la siguiente
grabación, los hablantes que casen aparecen con nombre y marcados como
reconocidos, con deshacer. **Registrar voz** (Rubén, 2026-10-08): además de
bautizar, en Personas se puede grabar una muestra de alguien y su huella se
suma a sus N; el audio de la muestra se borra al sacarla. La decisión de si dos huellas son la misma persona
va en `EscribaCore` como función pura y con test.

- **Una persona guarda N huellas**, no la media: cada bautizo añade una, y así
  se cubren distintos micrófonos y salas. Se compara con la más cercana.
- **Una persona por hablante en cada grabación**: dos hablantes de la misma
  nota no pueden ser la misma persona (asignación uno a uno).
- **Cada huella guarda el modelo que la generó**: si cambia el diarizador, las
  huellas viejas dejan de ser comparables.
- **Solo con diarización local**, que es la única que da huellas; los
  resolutores remotos no diarizan.
- **Las huellas no salen del Mac**: son datos biométricos y nunca van a los
  conectores.
- Sección **Personas** en la barra lateral: lista con nombre y número de
  huellas, quitar una huella, renombrar y fusionar.

*Criterio de salida*: en las grabaciones del paso 2, los nombres salen solos y
ningún falso positivo pasa sin poder deshacerse.

## Camino 2 (opción alternativa): precisar con Sortformer después

FluidAudio (Apache-2.0, Swift + CoreML, v0.17.5 del 2026-10-01) trae el modelo
**Sortformer** de NVIDIA, de diarización de extremo a extremo. Ordena a los
hablantes por llegada, así que sus etiquetas son estables, y **permite
inscribir voces conocidas** antes de diarizar un fichero completo
(`enrollSpeaker` + `processComplete(keepingEnrolledSpeakers:)`). En una prueba
de FluidAudio con cuatro personas, dos de voz muy parecida, las nombró a todas
con alta confianza.

### Cómo funcionaría

- **Una acción sobre una grabación ya hecha**, «Precisar hablantes», no un paso
  del pipeline. Más adelante podría lanzarse sola cuando el camino 1 dude (una
  distancia cerca del umbral).
- **No se vuelve a transcribir**: las palabras y sus tiempos ya están
  guardados. Sortformer vuelve a diarizar el audio y cada palabra se reasigna
  al hablante del tramo que más solapa.
- **Se inscribe solo a quien propuso el camino 1**, hasta cuatro personas. El
  camino 1 elige los candidatos y el 2 los afina.
- **Sale como una versión nueva** de la transcripción, como al reprocesar: no
  pisa la anterior y se puede volver a ella.

### Requisitos

- Solo se ofrece si la grabación tiene **cuatro hablantes o menos**.
- Las palabras que caigan en un tramo donde Sortformer no detecta a nadie
  (pierde habla en voz baja) **conservan el hablante del camino 1**.
- Cada persona guarda, además de sus huellas, **un clip corto de su voz** para
  inscribirla: la inscripción no persiste entre grabaciones y el audio original
  se puede quitar de la biblioteca. Los clips, como las huellas, no salen del
  Mac.
- Entra FluidAudio como dependencia. Si el camino 2 se queda, se pasa todo el
  diarizado a FluidAudio (también trae Community-1) en vez de mantener
  SpeakerKit y FluidAudio a la vez; las huellas viejas se invalidan por modelo.

### Límites conocidos (documentación de FluidAudio, 2026-10-06)

- Máximo cuatro hablantes únicos por grabación, inscritos incluidos.
- La inscripción es por instancia del diarizador y no crea una base de voces
  persistente.
- FluidAudio dice que la inscripción es **menos fiable que una base de huellas**
  de pyannote/WeSpeaker, que es lo que hace el camino 1. Por eso el camino 2
  afina y no sustituye.
- Su error más común es perder habla; los modelos (~100 MB) se descargan la
  primera vez; y en el benchmark independiente no gana a lo que ya hay.
- La base de voces de FluidAudio (`SpeakerManager`) vive en memoria y solo
  funciona con su diarización en tiempo real, así que no sirve para el camino 1.

*Criterio de entrada*: en el banco de pruebas, sobre grabaciones de hasta
cuatro hablantes, el camino 2 atribuye mejor que el camino 1 solo. Si no
mejora, no se construye.

Los modelos que transcriben y atribuyen hablante a la vez no son un tercer
camino: no dan huellas entre grabaciones
(`docs/exploracion-transcripcion-diarizacion.md`).

## Lo que no se hace

- **Activar el tratamiento de solapes**: en las medidas de FluidAudio sobre AMI
  empeoró el resultado (de ~38 % a ~53 % de error) porque el modelo se
  inventaba hablantes.
- **Cambiar de diarizador sin medir**: la diferencia entre sistemas es menor
  que la diferencia entre tipos de grabación.

## Banco de pruebas (medio día, reutilizable)

Tomar tres o cuatro grabaciones de la biblioteca que ya tengan transcripción
buena, pasarlas por los motores candidatos y comparar tiempo, texto y, para los
hablantes, cuánto coincide la atribución segundo a segundo con la versión dada
por buena. Cada vez que aparezca un motor nuevo se enchufa al mismo banco.

## Fuentes

- Benchmark independiente de diarizadores (2026): https://arxiv.org/html/2509.26177v1
- Streaming Sortformer: https://arxiv.org/abs/2507.18446
- FluidAudio, documentación de diarización: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
- FluidAudio, Sortformer e inscripción: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Sortformer.md
