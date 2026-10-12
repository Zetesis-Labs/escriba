# Trabajos

Encargo de Rubén del 2026-10-12. Especificación funcional; no describe la
implementación.

## 1. Resumen

Escriba ejecuta recetas sobre las notas en segundo plano, y hoy esas
ejecuciones solo se ven nota a nota y en la barra de menús; sus fallos acaban
en el Registro. La sección **Trabajos** reúne en un solo sitio lo que está en
marcha y lo que ya pasó, y permite actuar sobre ello: cancelar, volver a
lanzar, abrir la nota y leer el error completo.

Un **trabajo** es una ejecución de la receta de una nota, o de una de las tres
acciones manuales que también se encolan desde la nota: resumir a mano,
publicar en un destino y retirar una publicación. Transcribir, resumir o
publicar dentro de una receta no son trabajos distintos, sino etapas de la
misma ejecución.

Fuera de alcance: cambiar cómo se ejecutan o se reparten los trabajos (los
carriles siguen como están, ADR-0009) y cualquier cambio en la barra de menús
o en la vista de la nota.

## 2. Actores

- **Rubén**, único usuario de la app.
- **La cola de trabajos**, que reparte las ejecuciones en dos carriles: uno de
  inferencia (una a la vez) y uno de red (tres a la vez).
- **El runtime de recetas**, que ejecuta cada trabajo y avisa de su etapa.

## 3. Objetivos

- Saber qué se está ejecutando ahora, qué espera y por qué.
- Encontrar lo que ha fallado sin buscarlo en el Registro, y retomarlo.
- Cancelar algo en marcha sin tener que encontrar su nota.
- Que el historial no crezca sin límite.

## 4. Puntos de entrada

- **Barra lateral:** la sección «Trabajos», al mismo nivel que Biblioteca y
  Personas. Muestra cuántos trabajos hay en marcha; sin ninguno, no muestra
  número.
- **Ajustes:** el plazo del historial de trabajos.
- Sin cambios: el indicador de trabajo en cada nota, la barra de menús y el
  Registro siguen funcionando igual.

## 5. Recorridos

1. **Ver lo que está en marcha.** Al abrir Trabajos → la parte superior muestra
   los trabajos activos (en curso, en cola y esperando reintento). Se
   actualiza sola mientras la sección está abierta: cambia la etapa, aparecen
   los nuevos y los terminados pasan al historial. Termina cuando Rubén sale de
   la sección.
2. **Revisar el historial.** Debajo de los activos, los terminados, fallidos y
   cancelados dentro del plazo, del más reciente al más antiguo. Se muestran
   los 100 más recientes y, al llegar al final, se cargan otros 100. Rubén puede
   filtrar por estado (todos, terminados, fallidos, cancelados) y por receta
   o acción manual. Sin coincidencias, la lista lo dice; no se confunde con un
   error.
3. **Cancelar un trabajo activo.** Rubén cancela desde su fila → el trabajo
   pasa a cancelado igual que si se cancelara desde la nota: la receta deja de
   poder hacer nada más y, si estaba usando un motor local, también se corta.
   Si el trabajo terminó justo antes, queda como terminado y no se marca como
   cancelado.
4. **Volver a lanzar un trabajo fallido o cancelado.** Rubén lo relanza desde
   su fila → se encola un trabajo nuevo; el original se conserva en el
   historial tal cual. El nuevo es un trabajo más de esa nota y no indica de
   cuál viene.
   - Procesar usa la receta que tenga la nota en ese momento y crea una
     versión nueva, con las mismas reglas que reprocesar desde la nota.
   - Publicar, retirar o resumir a mano repiten la misma acción sobre el mismo
     destino o versión.
   - Si la nota ya tiene un trabajo activo, no se encola otro y se avisa.
   - Si hay un efecto externo incierto pendiente (por ejemplo, una página de
     Notion que pudo crearse o no), no se repite: se avisa de que hay que
     revisarlo antes, como hoy al reprocesar.
5. **Abrir la nota.** Desde una fila → Biblioteca con esa nota abierta.
6. **Ver el error completo.** En un trabajo fallido, Rubén despliega su error →
   se ve el mensaje entero y su código, no solo la primera línea.
7. **Cambiar el plazo del historial.** En Ajustes elige 7, 30 o 90 días, o
   «siempre»; por defecto, 7. Al reducirlo, lo que queda fuera se borra en el
   siguiente repaso.

## 6. Reglas

- **Estados.** En cola → en curso → terminado, fallido o esperando
  reintento. Desde esperando reintento vuelve a en curso cuando llega su
  hora. Cualquier estado activo puede pasar a cancelado. Terminado, fallido y
  cancelado son finales.
- **Orden de los activos:** primero los que están en curso, después los que
  esperan en cola por orden de llegada, y al final los que esperan reintento,
  con la hora del siguiente intento.
- **Una nota no tiene dos trabajos activos a la vez** (ya es así hoy).
- **Límite de tiempo:** un trabajo que pasa de dos horas falla por tiempo,
  como hoy, y aparece como fallido con ese motivo.
- **Receta de cada trabajo.** El historial muestra la receta con la que se
  ejecutó, aunque después la nota cambie de receta o la receta se borre o se
  renombre. El filtro por receta lista las que aparecen en el historial
  visible, más las tres acciones manuales.
- **Plazo del historial.**
  - Los trabajos terminados, fallidos y cancelados cuyo final es anterior al
    plazo se borran de la app y no se recuperan. Con «siempre» no se borra
    nada.
  - Nunca se borra un trabajo activo, ni uno de una nota con un efecto externo
    pendiente de revisar.
  - Borrar trabajos no toca notas, versiones, transcripciones ni
    publicaciones.
  - El repaso se hace al abrir la app y una vez al día.
- **Descartar una nota** borra sus trabajos, como hoy; desaparecen también del
  historial.
- **Registro:** los fallos de trabajos siguen apareciendo también en el
  Registro.
- **Errores de la propia sección:** si no se puede leer la lista, se muestra
  el error; nunca una lista vacía.

## 7. Conceptos

- **Trabajo:** nota (su título), receta o acción manual, estado, etapa en curso
  (mientras está activo), inicio, final o duración, siguiente intento (si
  espera reintento), y error con su código (si falló).
- **Acción manual:** resumir a mano, publicar en un destino o retirar una
  publicación; se lanzan desde la nota y se encolan como un trabajo más.
- **Plazo del historial:** 7, 30 o 90 días, o «siempre».

## 8. Interfaz

```
┌──────────────┬───────────────────────────────────────────────────────┐
│ Biblioteca   │ Trabajos                                              │
│ Personas     │                                                       │
│ Trabajos  ●  │ EN MARCHA                                             │
│ …            │ ▸ Reunión lunes · Receta resumen · Transcribiendo     │
│              │   desde 10:42 · 3 min                     [Cancelar]  │
│              │ ▸ Idea app · Publicar en Notion · En cola  [Cancelar] │
│              │ ▸ Llamada Ana · Receta resumen · Reintento 11:05      │
│              │                                                       │
│              │ HISTORIAL   [Estado: todos ▾] [Receta: todas ▾]       │
│              │ ✕ Paseo · Receta resumen · Fallido 10:31              │
│              │   «Resumen vacío…» [Ver error] [Relanzar] [Abrir nota] │
│              │ ✓ Notas 9 oct · Receta resumen · Terminado 09:58 · 4m │
│              │ ⊘ Prueba · Publicar en Notion · Cancelado 09:40        │
│              │                            [Relanzar] [Abrir nota]     │
└──────────────┴───────────────────────────────────────────────────────┘
```

- Cada fila muestra nota, receta o acción, estado, etapa y tiempos. Las
  acciones solo aparecen donde aplican: Cancelar en activos; Relanzar en
  fallidos y cancelados; Ver error en fallidos; Abrir nota en todos.
- Controles propios de la app, como el resto de secciones, sin búsqueda.

## 9. Restricciones

- No se puede cambiar la receta al relanzar; se usa la de la nota (o la acción
  original).
- No se reordena la cola ni se cambia la capacidad de los carriles.
- El historial borrado por plazo no se recupera.

## 10. Preguntas abiertas y supuestos

- **Confirmado:** el repaso del plazo se hace al abrir la app y una vez al día.
- **Confirmado:** el contador de la barra lateral cuenta los trabajos en
  marcha; el historial se carga de 100 en 100; un trabajo relanzado no indica
  de cuál viene.
- **Supuesto:** el error completo se despliega en la propia fila.
- **Requisito derivado:** hoy un trabajo no guarda con qué receta se ejecutó.
  Filtrar por receta exige que lo guarde al encolarse.
- **Supuesto:** la receta se guarda al encolar y se actualiza cuando el
  trabajo empieza a ejecutarse, para que el historial muestre la que de verdad
  se usó si la nota cambió de receta mientras esperaba.
- **Supuesto:** las pruebas de receta que se lanzan desde Recetas aparecen
  como «Prueba de la receta X», y relanzarlas repite la prueba con la misma
  receta, sin crear versión ni publicar.
- **Supuesto:** el repaso diario se comprueba cada hora con el reloj del Mac,
  para que un Mac dormido no lo retrase; borra en cuanto han pasado 24 horas
  desde el anterior.
- **Consecuencia:** la primera vez que se abre la app con esta sección, el
  repaso borra los trabajos terminados de hace más de 7 días, antes de que se
  pueda elegir otro plazo. Los trabajos guardados antes de esta versión no
  tienen hora de final y se datan por su creación.
