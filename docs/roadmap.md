# Roadmap de Escriba

Qué se está haciendo, qué viene después, qué quedó a medias y qué espera una
decisión de Rubén. Actualizado el 2026-10-07. Este fichero es el índice: cada
cosa grande tiene su documento con el análisis y los criterios de salida.

## Orden

1. **Recetas**: `requisito-recetas.md`. En construcción desde el 2026-10-07.
   - Hecho: fase 1 (capacidades que recuerdan lo hecho), fase 2 (motor de
     JavaScriptCore y receta por defecto en TypeScript), fase 3
     (una lista de recetas de formulario y de código con una por defecto, el
     proyecto en una carpeta del usuario compilado con esbuild, reprocesar con
     una receta) y la fase 6 (`procesar`: una receta pasa la grabación a otra).
   - Hecho también (2026-10-08): depurar (`console`, historial de
     ejecuciones, ficha de la receta, sección Registro, errores con la línea
     del TypeScript) y «Probar con…» (RF-15).
   - Siguiente: la fase 4.
   - Fase 4: `escriba.preguntar` con respuesta estructurada (RF-6) y `datos`
     por versión que la biblioteca muestra y filtra (RF-7); de paso, buscar
     dentro de las transcripciones.
   - Fase 5: la receta decide qué carga manda a cada conector (RF-9) y se
     borran los editores de mapeo, verificando contra una base real de
     Notion. Propuesto, sin decidir: que el conector sea la cuenta y su
     alcance (las bases compartidas con la integración, la carpeta raíz de
     OKF) y la receta elija el destino dentro.
   - Fase 7, opcional: Escriba escribe una receta con su propio LLM.
   - Sin decidir: acceso por MCP (RF-17).
   - Descartado el 2026-10-07: receta por carpeta y al grabar o importar,
     «Personalizar…», convertir una receta de formulario en código, exportar e
     importar recetas sueltas. Aparcado: el editor Monaco dentro de la app.
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

- **Publicar en Notion con el editor de conectores nuevo** (columna a valor
  con datos, cuerpo de texto a bloques) sin probar todavía contra una base de
  verdad. Con la fase 5 ese editor desaparece.
- **Rotar el log de la app** (`~/Library/Logs/escriba.log`): no se rota y
  pasaba de 50 MB, casi todo por el reintento de grabaciones vacías y
  descartadas, ya arreglado el 2026-10-08.

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
