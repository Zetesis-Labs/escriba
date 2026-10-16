# Combinar grabaciones

Encargo de Rubén del 2026-10-16, decidido en conversación y construido el
2026-10-17 en la rama `feat/recetas-modulares`. Especificación funcional; no
describe la implementación.

## 1. Resumen

Una conversación grabada en varios trozos (una pausa, un cambio de sitio, el
micrófono que se cortó) acaba hoy en varias notas sueltas, cada una con su
transcripción y su resumen a medias. **Combinar** junta varias grabaciones de
la biblioteca en una sola, en el orden que la persona elija, y la trata como
cualquier grabación que entra: se transcribe, se resume y se publica desde
cero con la receta por defecto. No hay conceptos nuevos: el resultado es una
grabación normal cuyo audio es la unión de las piezas, con un segundo de
silencio entre cada dos, y que recuerda de qué grabaciones salió y en qué
segundo empieza y acaba cada una.

Para poder elegir varias, la lista de Biblioteca pasa a admitir **selección
múltiple**. Con varias filas marcadas, el menú contextual ofrece por ahora
solo «Combinar…»; qué más acciones admite esa selección se decide aparte.

Fuera de alcance: reaprovechar transcripciones o resúmenes de las piezas,
recortar o solapar audios, y deshacer una combinación. Las publicaciones no
cambian (§10 de la spec de recetas).

## 2. Actores

- **Rubén**, único usuario de la app.
- **El host nativo**, que lee las copias de audio y escribe la unión.
- **La cola de trabajos**, que recoge la grabación combinada como cualquier
  grabación pendiente y le aplica la receta por defecto.

## 3. Objetivos

- Convertir N notas de una misma conversación en una sola con un gesto.
- Elegir el orden sin reglas ocultas: el que la persona ponga.
- Decidir en el mismo gesto si las piezas originales se quedan o se van.
- Que la grabación combinada no se distinga de las demás en nada, salvo en
  que sabe de qué piezas está hecha.

## 4. Puntos de entrada

- **Biblioteca → selección múltiple → menú contextual → «Combinar…».** Única
  entrada. Con una sola fila marcada no aparece.
- No hay combinación desde Trabajos, desde la ficha de una nota ni desde el
  menú de la barra.

## 5. Flujos

1. **Seleccionar varias.** Clic marca una fila y desmarca el resto; ⌘-clic
   añade o quita una; ⇧-clic marca el tramo desde la última marcada; las
   flechas mueven la marca única. El detalle muestra la última fila marcada.
2. **Combinar.** Clic derecho sobre una de las marcadas → «Combinar…» →
   **hoja** con las piezas en el orden inicial (de la más antigua a la más
   reciente) y, en cada una, su título, su fecha y su duración si se conoce.
   Flechas de subir y bajar cambian el orden; sirve para dos piezas o para
   diez. Debajo, qué hacer con las originales: «Conservarlas» (de serie) o
   «Borrarlas de la biblioteca». Botón «Combinar».
3. **Aviso si se borran.** Si eligió borrarlas, antes de combinar aparece la
   confirmación destructiva de «Borrar de la biblioteca» para N notas: se van
   sus filas, sus transcripciones y sus copias de audio; los archivos
   originales en sus carpetas no se tocan; sus publicaciones siguen donde
   estén y la grabación combinada volverá a publicar; sus vínculos de
   conocimiento quedan huérfanos, como al descartar cualquier nota.
4. **Unión del audio.** La hoja espera con un indicador mientras el host une
   las piezas. No se puede cancelar a medias. Al terminar, la grabación
   combinada aparece en la biblioteca como pendiente, queda marcada, y las
   originales desaparecen si así se pidió. Todo o nada: si la unión falla, no
   cambia nada y la hoja muestra el error.
5. **Procesar.** La cola la recoge como cualquier grabación pendiente y le
   aplica la receta por defecto: transcribe, resume y publica según esté
   configurada. Desde ahí es una nota normal: versiones, correcciones,
   reprocesar, publicar, borrar.
6. **Ver de qué está hecha.** La ficha de la grabación combinada muestra sus
   piezas en orden, con el título que tenía cada una al combinar y el minuto
   en que empieza y acaba dentro del audio. Si una original se borró, el
   título sigue ahí.

## 6. Reglas

- «Combinar…» solo se ofrece con dos o más filas marcadas, y solo se puede
  pulsar si todas tienen copia de audio, ninguna está descartada y ninguna
  tiene un trabajo en marcha. Si no, el elemento sale apagado.
- El audio combinado va en el formato de las grabaciones propias (AAC en
  `.m4a`), con **un segundo de silencio** entre cada dos piezas, sin recortes
  ni normalización. Las piezas conservan su duración; los segundos de
  inicio y fin de cada una los mide el host al unirlas, no se calculan a
  partir de la biblioteca.
- La fecha de la grabación combinada es la de la primera pieza en el orden
  elegido. Su título de partida es «Grabación combinada»; el resumen lo
  sustituye como en cualquier nota. Su origen es «Combinación».
- La grabación combinada es nueva aunque las piezas ya estuvieran
  combinadas antes; combinar las mismas piezas en el mismo orden dos veces
  da la misma grabación (misma identidad de contenido), como importar dos
  veces el mismo archivo.
- Una pieza cuyo formato el host no sabe leer hace fallar la combinación
  nombrando la nota y el formato; no se produce nada.
- Borrar las originales es exactamente «Borrar de la biblioteca» de cada una,
  en la misma operación que crea la combinada: queda su lápida, se retira su
  copia de audio, se cancelan sus trabajos pendientes (no puede haberlos en
  marcha por la regla anterior) y los archivos originales no se tocan.
- La combinación no es un trabajo de la cola: no sale en Trabajos y no
  sobrevive a cerrar la ventana mientras el host une el audio.
- Linux: el host nativo de Linux no une audio todavía; «Combinar…» falla ahí
  con «no disponible» hasta que lo tenga.

## 7. Conceptos

- **Grabación combinada**: grabación normal cuyo audio es la unión de varias
  piezas. Tiene, además de lo de cualquier grabación, su lista de piezas.
- **Pieza**: tramo de una grabación combinada: la grabación de origen (su
  identidad y el título que tenía al combinar) y el segundo en que empieza y
  acaba dentro del audio combinado.
- **Selección**: conjunto de filas marcadas en Biblioteca, con una de ellas
  como última marcada, que es la que muestra el detalle y el ancla de ⇧-clic.

## 8. Pantalla

- Lista de Biblioteca con varias filas marcadas a la vez, con el mismo
  resalte que hoy; el detalle de la derecha muestra la última marcada.
- Hoja «Combinar grabaciones»: lista ordenable de piezas (título, fecha,
  duración, flechas ↑ ↓), selector «Después de combinar: Conservar las
  originales / Borrarlas de la biblioteca», botones «Cancelar» y «Combinar»;
  durante la unión, indicador de actividad y botones apagados.
- Ficha de la grabación combinada: bajo los metadatos, «Formada por» con una
  línea por pieza: título, minuto de inicio y de fin.

## 9. Límites y renuncias

- Sin deshacer: una vez combinada, separar es volver a importar los
  archivos originales.
- Sin recortes, solapes ni ajuste de volumen entre piezas.
- Sin arrastrar para ordenar: flechas.
- La unión bloquea la hoja mientras dura; con audios de horas puede tardar
  minutos. Si en la prueba resulta molesto, el siguiente paso es convertirla
  en un trabajo de la cola, no un rediseño.

## 10. Preguntas abiertas y supuestos

- Qué otras acciones ofrece el menú contextual con varias filas marcadas
  (borrar varias, reprocesar varias…): Rubén las decide cuando toque.
- Supuesto: el título de partida «Grabación combinada» y la fecha de la
  primera pieza son mis elecciones; Rubén no las ha fijado.
- Supuesto: el formato de salida es el de las grabaciones propias (AAC,
  mono, 48 kHz). Si una pieza es estéreo, se mezcla a mono.
