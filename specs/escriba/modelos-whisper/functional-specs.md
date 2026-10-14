# Modelos de Whisper local

Encargo de Rubén del 2026-10-14: en macOS, en Linux y, cuando exista, en
Windows, la persona elige qué modelos de Whisper local tiene instalados, y
puede tener varios. Cada modelo instalado es un resolutor local más que las
recetas eligen como cualquier otro (opción A, decidida por Rubén el
2026-10-14).

## 1. Resumen

Hoy hay un solo Whisper local con un modelo fijo por sistema. Con este cambio,
STT ofrece el catálogo de modelos del motor local de cada sistema (WhisperKit
en el Mac, whisper.cpp en Linux) y cada modelo que se añade aparece en la lista
de STT como un resolutor local. Así una receta puede transcribir con un modelo
rápido y otra con uno grande.

## 2. Recorridos

**R1. Añadir un modelo.** En STT, el botón «+» ofrece, además de los servicios
remotos, los modelos locales del catálogo que aún no están en la lista, con su
tamaño aproximado. Al elegir uno aparece en la lista como «Whisper · <modelo>»
y su ficha permite descargarlo, con progreso, como hoy el de serie.

**R2. Usarlo.** En Recetas, «Transcribe con» lista el Whisper de serie, los
modelos añadidos y los remotos. Una nota que llega a un modelo sin descargar
espera como «no disponible», igual que hoy con el de serie.

**R3. Borrar o quitar.** «Borrar del disco» borra solo ese modelo; el
resolutor sigue en la lista para volver a descargarlo. «Quitar» (−) saca de la
lista un modelo añadido, pero no lo borra del disco: borrar es siempre la
acción explícita. Las recetas que lo usaban pasan al Whisper de serie.

## 3. Reglas

- El Whisper de serie («Whisper · en este Mac» o «en este equipo») siempre está,
  va el primero y no se puede quitar. Su modelo es el de serie de cada sistema.
  La receta que no elige STT usa el Whisper de serie.
- Cada resolutor local tiene su modelo, y es el que se usa al transcribir y en
  la huella de reutilización: dos modelos distintos no comparten transcripción.
- Un modelo es un nombre del catálogo de su sistema, sin rutas.
- El catálogo, los tamaños y qué está instalado los da el motor de cada
  sistema; la interfaz no los conoce de antemano.
- Detectar hablantes sigue siendo solo con Whisper local, con cualquiera de sus
  modelos.
- Una biblioteca existente conserva lo que tenía: el Whisper de serie sigue con
  su modelo y no aparecen modelos nuevos hasta que se añaden.

## 4. Interfaz

- **STT, lista:** cada resolutor local con su nombre y el subtítulo «En este
  Mac» o «En este equipo», más el modelo en los añadidos.
- **STT, «+»:** servicios remotos, separador y los modelos del catálogo que
  faltan, con «unos N MB/GB».
- **STT, ficha de un modelo local:** estado (descargado y tamaño, descargando,
  no descargado), «Descargar» o «Borrar del disco».

## 5. Fuera de alcance

- Modelos que no estén en el catálogo del motor (rutas o URL propias).
- Varios LLM locales: Linux no incluye LLM y el Mac solo tiene Apple
  Intelligence.

## 6. Reparto por sistema

El protocolo nativo gana `models` (catálogo con tamaño e instalados) y
`deleteModel` (borra un modelo). Linux los implementa en el host de Rust. En el
Mac los implementa la sesión del Mac en Swift con el catálogo de WhisperKit;
hasta entonces el Mac se comporta como hoy, con un único modelo.
