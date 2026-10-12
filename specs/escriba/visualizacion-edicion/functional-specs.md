# Visualización y edición de notas

## Resumen

Primera entrega acordada con Rubén el 2026-10-11: mejorar conjuntamente la
legibilidad del detalle y el control manual del contenido. Se conserva la
biblioteca maestro–detalle y el diseño macOS. Este encargo reabre expresamente
las restricciones anteriores sobre edición manual de transcripciones, resumen,
título, etiquetas y datos.

Los borradores agrupan las correcciones sin generar una versión por cada cambio.
El grafo de conocimiento y los filtros de biblioteca son iniciativas posteriores
e independientes; no bloquean esta entrega. Los embeddings quedan fuera.

## Actores y roles

- Usuario de Escriba: consulta, escucha y corrige sus notas.
- Conectores configurados: reciben la actualización de publicaciones existentes
  después de confirmar los cambios, siguiendo el funcionamiento de la biblioteca.

## Objetivos y tareas

- Distinguir título, descripción, resumen, etiquetas, datos, transcripción y
  ejecución de receta sin enfrentarse a un único bloque de texto.
- Corregir manualmente el contenido y la atribución de palabras a hablantes.
- Elegir una persona guardada sin volver a escribir su nombre.
- Revisar conjuntamente las correcciones y confirmar una sola versión.

## Puntos de entrada

Detalle de una grabación, acción Editar, campos del contenido, controles de
hablante y menú contextual sobre la selección de texto. Guardar cambios y
Descartar cierran el borrador. Las ejecuciones se consultan desde el detalle y
desde el Registro existentes.

## Flujos

1. Abrir una nota → ver secciones diferenciadas y reproducción sincronizada.
   Si existe un borrador, se recupera para continuar la edición.
2. Editar → corregir título, descripción, resumen, etiquetas, datos o texto →
   conservar las modificaciones en un borrador, sin nuevas versiones ni
   publicaciones. Los fallos al conservarlo se muestran de forma visible.
3. Seleccionar palabras → menú contextual Asignar hablante → elegir una persona
   guardada, otro hablante de la nota o escribir un nombre → cambiar solamente
   la selección. El texto anterior y posterior mantiene su atribución.
4. Pulsar el hablante de una intervención → elegir a quién corresponde →
   guardar la corrección en el mismo borrador. Renombrar un hablante en toda
   la nota se distingue de cambiar una intervención o selección.
5. Guardar cambios → confirmar conjuntamente el contenido corregido → crear
   una sola versión y conservar la original. Si no hubo cambios, no se genera
   una versión duplicada. Las publicaciones existentes se actualizan después.
6. Descartar → eliminar el borrador → recuperar el contenido confirmado.
7. Abrir la ejecución → ver receta, resultado, duración y pasos con sus errores
   y resultados disponibles. Los detalles no registrados no se inventan.
8. Personas → elegir una persona → cambiar su color. La lista, la transcripción
   y el selector de hablantes usan ese color, conservado al reiniciar.

## Reglas y restricciones funcionales

- Una corrección no modifica silenciosamente las versiones históricas.
- Un borrador se conserva al cambiar de nota y reiniciar Escriba una vez
  confirmada su conservación; la interfaz distingue Guardando de Guardado.
- Si la versión de origen cambia durante la edición, no se sobrescribe:
  el usuario ve el conflicto y mantiene acceso al borrador.
- Guardar dos veces la misma confirmación no crea dos versiones.
- La asignación parcial no enseña automáticamente a Personas una huella de
  toda la intervención. Las muestras biométricas no se editan desde esta vista.
- Los fragmentos consecutivos del mismo hablante forman un bloque visual con
  una sola cabecera. La cabecera reasigna ese bloque; la selección de palabras
  permite separar un fragmento, manteniendo los índices y tiempos originales.
- Cada persona guardada puede tener un color propio. Sin color elegido se usa
  uno automático estable. El nombre sigue visible para no depender solo del color.
  Renombrar conserva el color; juntar personas conserva el del destino si existe.
- Se conservan los tiempos originales de las palabras cuando existen. Si no
  existe ese detalle, el fragmento conserva el intervalo de su intervención
  y la interfaz comunica esa limitación al reproducirlo.
- Los errores de actualización externa no borran la corrección local guardada.
- Las pruebas usan notas sintéticas; nunca se publican notas reales en Notion.

## Conceptos de datos

Nota, versión, borrador de versión, transcripción, intervención, selección de
palabras, hablante, persona guardada, resumen, etiqueta, dato y ejecución de receta.
El borrador pertenece a una nota y tiene una versión de origen. No es una nueva
ejecución de la receta ni una publicación.

## Representación gráfica

Se conservan barra lateral, lista de notas y barra de herramientas. En el detalle:

```text
Reproductor
Estado del borrador             Descartar · Guardar cambios / Editar
Título
Fecha · origen · duración · versión
Descripción y etiquetas

Resumen                        texto o campo editable
Datos                          campos identificados por sus etiquetas
Transcripción                  hablante · tiempo · intervención
Cómo se procesó                 receta · estado · duración · pasos
```

Jerarquía tipográfica, espaciado y separadores discretos. Colores del sistema,
modos claro/oscuro existentes, controles y menús de aspecto macOS. La selección
de texto sigue disponible para copiar y asignar palabras. No se añade un editor
de código ni una pantalla separada para corregir la nota.

## Límites y decisiones

- No incluye grafo, filtros, búsqueda semántica ni nuevas técnicas de diarización.
- La edición abarca contenido de la nota; origen del audio, duración medida,
  fecha de captura e historial técnico siguen siendo metadatos de lectura.
- Los datos estructurados conservan sus tipos y etiquetas del esquema. El
  usuario modifica los valores; esta entrega no es un diseñador de esquemas.

## Preguntas abiertas y supuestos

- Supuesto de implementación: se conserva un borrador por nota. Abrir de nuevo
  la nota continúa ese borrador; no se añade una lista de borradores alternativos.
- La integración con el futuro grafo se definirá en su propio requisito. No se
  introduce ahora un modelo de entidades o relaciones a partir de estas pantallas.

## Verificación de esta entrega

- Pruebas de decisiones de texto: selección parcial y entre intervenciones,
  conservación de texto y tiempos, retirada de reconocimientos ambiguos.
- Pruebas del controlador: guardados sucesivos, recuperación de errores,
  conflictos y confirmaciones idempotentes.
- Pruebas con RocksDB real: reapertura, rollback transaccional, aislamiento
  del borrador, conservación de versiones y huellas no ambiguas.
- Recorrido de interfaz con notas sintéticas: corregir campos, elegir una
  persona, reasignar palabras entre intervenciones, navegar y recuperar,
  confirmar una sola versión, descartar y bloquear números inválidos.
- Capturas comprobadas en claro, oscuro y ancho mínimo de 960 px.
- Agrupación por hablante, selección dentro del bloque y color por persona:
  comprobación visual sintética y persistencia con RocksDB real.

Rubén validó la visualización y el uso en la aplicación instalada el 2026-10-11,
incluidos los bloques consecutivos por hablante y los colores por persona.
