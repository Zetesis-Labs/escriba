# jpr-transcribe

Transcriptor automático de notas de voz, en Swift, camino de ser una app propia
con biblioteca de grabaciones. El `README.md` explica el dominio (iCloud,
asentamiento, ledger, backends); esto son las reglas para tocar el código.

**Alcance**: utilidad personal de Rubén — transcriptor automático + UI de
seguimiento. Sin objetivo de comercializar: simplicidad de utilidad propia
antes que generalidad (nada de onboarding, distribución ni features
especulativas).

## Comandos

```bash
swift build                 # CLI + app
swift test                  # swift-testing; --filter NO casa con nombres de @Suite
./scripts/build-app.sh      # .build/app/JPR Transcribe.app
./scripts/install-app.sh    # a /Applications (la firma ad-hoc puede invalidar el Acceso total al disco)
```

## Arquitectura: núcleo funcional, cáscara imperativa

| Target | Qué | I/O | Dependencias |
|---|---|---|---|
| `JPRCore` | Modelo (`Transcript`, `Recording`), parseo, decisiones | ninguno | ninguna |
| `JPRKit` | FSEvents, ledger, procesos, orquestación (`Pipeline`) | sí | ninguna |
| `JPRWhisperKit` | Backend WhisperKit + SpeakerKit | sí | argmax-oss-swift |
| `JPRStore` | Biblioteca SQLite + copia del audio | sí | GRDB |
| `jpr-transcribe` | CLI | | |
| `JPRMenuBar` | App de barra de menús | | aislamiento MainActor por defecto |

- **Los puertos son structs de funciones**, no protocolos ni herencia:
  `TranscriptionBackend`, `RecordingSource`, `Sink`. Una implementación nueva
  es una función `make(...)` que devuelve el struct.
- **Toda decisión va en `JPRCore` como función pura y con test.** La cáscara
  solo ejecuta. Si un bloque pide un comentario, extráelo a una función con
  nombre.
- **Cada dependencia externa vive en su propio target.** `JPRCore` y `JPRKit`
  no importan nada.
- **Tests primero**, con swift-testing (`@Suite`/`@Test`/`#expect`), nunca
  XCTest. Los nombres de test describen el comportamiento en castellano.

## Decisiones cerradas (no reabrir)

- **Mínimo macOS 26 / tools 6.2, a propósito**: da `Observations`,
  FoundationModels, SpeechAnalyzer y el aislamiento por defecto. No bajarlo.
- **Nada de Combine.** Notificaciones a la UI con `AsyncSequence`
  (`ValueObservation.values(in:)`, `Observations`) sobre modelos
  `@MainActor @Observable`. `Observations` exige el modelo en `@MainActor`
  o pide `Sendable` y no compila.
- **GRDB, nunca SwiftData ni Core Data**: clavan los datos a Apple y bloquean
  `sqlite-vec`.
- **El pipeline no adivina cuántos hablan.** Guarda lo que sale; la corrección
  (`merging`, `renaming`, `--speakers-count N`) es de la app.
- **La app se descarga sus modelos** a
  `~/Library/Application Support/jpr-transcribe/models`; nunca reutiliza los
  de MacWhisper.
- **WhisperKit es el backend por defecto** (decidido 2026-08-31). MacWhisper
  queda como contraste vía `--backend macwhisper`; no depender de él.

## Swift moderno: qué se usa y dónde

Directriz (2026-08-31): usar lo último del lenguaje, cada cosa donde paga.

- **Concurrencia estricta Swift 6** en todo; aislamiento MainActor por defecto
  en los targets de UI; `@concurrent` para trabajo pesado fuera del main actor.
- **AsyncSequence como transporte único**: `values(in:)` de GRDB,
  `Observations`, `AsyncStream` para puentear callbacks (FSEvents, time
  observers de AVPlayer). Nada de Combine ni `NotificationCenter`.
- **Typed throws en los puertos** (`throws(TranscriptionError)`) cuando se
  toquen (Fase 6d).
- **`Mutex` (Synchronization) donde sobreviva un lock**; `NSLock` es legado.
- **Ownership donde es real, no adorno**: `~Copyable` para recursos de un solo
  dueño (`InstanceLock`/flock); `Span<Float>`/`borrowing` para mirar PCM sin
  copiarlo (una hora a 16 kHz float ≈ 230 MB). El resto no lo necesita.
- Sin caso aquí: Embedded Swift, interop C++, `InlineArray`.

## Trampas del stack

- `DecodingOptions.skipSpecialTokens` viene en `false`: sin activarlo el
  texto sale con `<|startoftranscript|><|0.00|>…`.
- `WhisperKit` y `WhisperKitConfig` **no son `Sendable`**: el kit vive dentro
  de un `actor` y solo cruzan la frontera tipos que sí lo son.
- `SpeakerSegment.text` sale de `speakerWords`, no de `transcription`: sin
  `wordTimestamps` las transcripciones diarizadas salen vacías **en silencio**.
- `SpeakerInfo` es enum no-frozen con `.noMatch` y `.multiple`: `@unknown default`.
- `SpeakerKit.diarize` pide PCM 16 kHz en memoria
  (`AudioProcessor.loadAudioAsFloatArray`), no una ruta.
- HubApi deja metadatos en `.cache` con el mismo nombre que la carpeta del
  modelo, y la carpeta existe desde el primer byte: un modelo está completo
  solo si tiene los tres `.mlmodelc` con `coremldata.bin`.
- Los métodos de WhisperKit son `open func`, no `public func` (grep engañoso).
- `mw` imprime `Transcribing X.m4a...` antes del JSON.
- Grabaciones multicanal: los canales se suman a mono y la diarización se
  degrada. Pendiente diarizar por canal.
- `isolated deinit` con el aislamiento por defecto del target compila en
  debug pero **release exige el `@MainActor` explícito en la clase**.
- El modelo se descarga solo tras 5 min sin trabajo (`IdleUnloader`); el RSS
  no vuelve del todo (malloc retiene páginas), pero los objetos se liberan.
