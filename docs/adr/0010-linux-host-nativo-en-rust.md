# Linux primero, host nativo en Rust y Swift al mínimo

Decidido por Rubén el 2026-10-13. Sustituye la decisión registrada en
`docs/requisito-multiplataforma.md` (SwiftUI en el Mac y SwiftCrossUI fuera).
El comportamiento esperado en Linux está en
`specs/escriba/linux/functional-specs.md`.

## Contexto

`requisito-multiplataforma.md` se escribió cuando la interfaz era SwiftUI: lo
caro de llevar Escriba fuera del Mac era rehacerla. Desde el ADR-0005 la
interfaz es React sobre Tauri y el host es Rust; ambos corren en Linux casi sin
cambios. Lo que ata a macOS es `EscribaNativeHost`, que envuelve APIs de Apple
(WhisperKit, SpeakerKit, FoundationModels, AVFoundation, iCloud), y el aislamiento
de recetas con `sandbox-exec`.

Swift fuera del Mac no tiene nada que envolver. Además, desde el ADR-0007 no
compila en Linux: `1a78fe2` retiró `CSQLite` y EscribaSystemKit falla con
`no such module 'SQLite3'` (comprobado el 2026-10-13 en `swift:6.4-noble`;
reponer el target lo arregla).

## Decisión

1. **Linux es la primera plataforma fuera del Mac.** Windows queda fuera de
   este encargo.
2. **Las capacidades nativas que no exigen una API de Apple se implementan en
   Rust** y hablan el protocolo v1 de `docs/tauri-native-protocol.md`. La misma
   implementación sirve en Linux y en el Mac. Se mantiene el modelo actual de
   proceso aparte bajo el supervisor Rust, de modo que un fallo del motor no
   cierra la app y se conservan la descarga por inactividad y la cancelación.
3. **Swift al mínimo.** En el Mac pasan a Rust `audioInfo`, `fileStatus`,
   `materialize` y la grabación, sin cambios visibles: mismos permisos y mismo
   formato, porque el AAC se codifica con AudioToolbox, que es una API C y no
   necesita Swift. Cada sistema usa el motor que mejor encaja con él: en el Mac
   siguen WhisperKit, SpeakerKit y FoundationModels en Swift; en Linux, los que
   mejor funcionen allí. Linux no incluye LLM: resumir y preguntar usan
   resolutores.
4. **Linux no compila ni empaqueta Swift.** No se recupera `CSQLite`; el CLI
   `escriba` sigue siendo solo de Mac (ADR-0007, decisión 2).

## Alternativas descartadas

- **SwiftCrossUI fuera del Mac.** Partía de una interfaz Swift que ya no existe.
- **`EscribaNativeHost` en Swift también en Linux.** Habría que recuperar
  `CSQLite` y el job de Linux, y empaquetar el runtime de Swift para envolver
  bibliotecas C que Rust usa directamente.
- **Un motor común en el Mac y en Linux.** En el Mac, WhisperKit aprovecha el
  Neural Engine y FoundationModels solo existe en Swift.

## Consecuencias

- `transcribe`, `diarizedVoices` y `downloadModel` tienen dos implementaciones
  de forma permanente: hace falta una batería de pruebas del protocolo común a
  ambas, o se separan. `summarize` y `ask` solo existen en el Mac; en Linux
  responden `backend_unavailable`.
- En el Mac conviven dos procesos nativos y Rust envía cada método al suyo.
  `status`, que hoy responde a la vez por Whisper y por el LLM, se reparte entre
  los dos.
- Las huellas de voz dependen del motor y no son comparables entre sistemas.
  No importa porque una biblioteca no pasa del Mac a Linux.
- Linux necesita su propio aislamiento de recetas con la misma garantía
  (tokens, rutas de audio y huellas no llegan a las recetas). El mecanismo no se
  decide aquí; es también el pendiente de sustituir `sandbox-exec` del ADR-0007.
  Si el equipo no lo permite, las recetas se ejecutan sin aislar con un aviso
  permanente (decidido por Rubén el 2026-10-13, por simplicidad).
- Hay que quitar del host Rust lo que da por hecho macOS: bookmarks de
  `folder_access.rs`, `/usr/bin/open`, enlaces `x-apple.systempreferences`, la
  ruta de modelos fijada en `Application Support` y el lanzador `sh` del
  proyecto de recetas.
- Al mover la grabación del Mac a Rust hay que comprobar en la app instalada que
  el permiso de micrófono ya concedido se conserva.
- `docs/requisito-multiplataforma.md` queda como historia; su tabla de piezas a
  sustituir sigue siendo útil.
