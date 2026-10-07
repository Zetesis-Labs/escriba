# Roadmap de Escriba

Qué se está haciendo, qué viene después, qué quedó a medias y qué espera una
decisión de Rubén. Actualizado el 2026-10-07. Este fichero es el índice: cada
cosa grande tiene su documento con el análisis y los criterios de salida.

## Orden

1. **Recetas**: `requisito-recetas.md`. En curso desde el 2026-10-07, por la
   fase 1 de 7 (capacidades que recuerdan lo hecho, sin cambio visible). De 5
   a 7 semanas con el editor. La búsqueda dentro de las transcripciones entra
   aquí, en la fase 4 (RF-7).
2. **Personas**: `requisito-hablantes.md`. Bautizar a alguien una vez y que se
   le reconozca en las siguientes grabaciones. Primero el camino 1 (huellas
   propias guardadas por Escriba); el camino 2 (Sortformer con voces
   inscritas) solo si el banco de pruebas demuestra que mejora.

## A medias

- **Transcribir con un proveedor externo.** Funciona con cualquier API
  compatible con OpenAI, pero sin hablantes, y la interfaz lo avisa. Falta
  diarizar en local y unir por tiempos en el núcleo. Con la dirección de
  computación local (2026-10-06) no corre prisa.

## Pendientes pequeños

- **El resumen no llega al `.txt`**: va a la biblioteca y a los conectores,
  pero `writeSidecarText` solo escribe la transcripción.
- **Publicar en Notion con el editor de conectores nuevo** (columna a valor
  con datos, cuerpo de texto a bloques) sin probar todavía contra una base de
  verdad.

## Esperando una decisión

- **Publicar una versión descargable.** No hay ninguna release: hoy nadie usa
  Escriba sin clonar y compilar, y eso contradice el alcance («cualquiera se
  lo baja»). Hay que decidir entre notarizar con una cuenta de desarrollador
  de Apple o que el primer release pida abrirla saltándose Gatekeeper a mano.
  Si se notariza, las recetas necesitarán el permiso
  `com.apple.security.cs.allow-jit` (RF-16).

## Hecho del orden anterior (2026-09-22)

- Fichero de licencia: MIT, el 2026-10-05.
- Resumir con un proveedor externo: PR #2, junto a los resolutores de STT y
  LLM.

## Aparcado o descartado (no reabrir sin pedirlo)

- **Escritorio en Windows y Linux**: `requisito-multiplataforma.md`. Si se
  retoma, la decisión ya está tomada (SwiftUI en el Mac y SwiftCrossUI fuera).
- **Conectores como plugins WebAssembly**: `exploracion-plugins-wasm.md`, con
  el código en el PR en borrador #3.
- **Hooks del usuario**: sustituidos por las recetas
  (`requisito-hooks.md`).
