# Exploración: transcripción y diarización, lo más moderno (octubre de 2026)

Estado: **opción documentada el 2026-10-06**, sin decisión de cambiar de
motor. Dirección fijada por Rubén: **computación local**. Lo remoto queda como
referencia y como resolutor opcional, que Escriba ya admite, pero no es hacia
donde va el producto.

## Qué hay hoy

- **Transcribir**: WhisperKit con Whisper large-v3 turbo, en CoreML.
- **Diarizar**: SpeakerKit, que ejecuta pyannote Community-1 (pyannote v4) en
  CoreML.
- **Unir**: cada palabra hereda el hablante del tramo en el que cae.
- **Huellas**: SpeakerKit calcula una por hablante y se tira; solo se anotan
  las distancias en el log (`docs/requisito-hablantes.md`).

## Las dos tendencias

1. **Modelos conjuntos**: un solo modelo transcribe y atribuye hablante en una
   pasada, en vez de dos modelos unidos por tiempos.
2. **Voces conocidas**: inscribir a una persona con una muestra y que el
   sistema la reconozca por su huella. Es la feature de Personas.

## Opciones locales

### Por piezas: transcribir y diarizar por separado

| Pieza | Opción | En el Mac | Notas |
|---|---|---|---|
| Transcribir | Whisper large-v3 turbo | Lo actual (WhisperKit) | 99 idiomas |
| Transcribir | Parakeet TDT v3 y Parakeet Ultra (NVIDIA) | CoreML en el Neural Engine, vía FluidAudio | 25 idiomas europeos con español; Ultra es más preciso a la misma velocidad, según FluidAudio |
| Transcribir | Granite Speech 4.1 2B (IBM) | Sin CoreML; hay GGUF para transcribe.cpp | Primero del Open ASR Leaderboard; español, inglés, francés, alemán, portugués y japonés |
| Transcribir | Canary-Qwen 2.5B (NVIDIA) | — | Solo inglés: descartado |
| Diarizar | pyannote Community-1 | Lo actual (SpeakerKit); también en FluidAudio | Lo mejor en abierto; según pyannote supera a la mayoría de los comerciales en DIHARD |
| Diarizar | Sortformer (NVIDIA) | CoreML, vía FluidAudio | Máximo 4 hablantes; la mejor inscripción de voces conocidas según FluidAudio |
| Diarizar | LS-EEND | CoreML, vía FluidAudio | En tiempo real, hasta 10 hablantes; inscripción débil con voces parecidas |
| Diarizar | DiariZen (WavLM) | Port de terceros a CoreML y Swift | Sin tope de hablantes |

Cifras publicadas:

| Medida | Valor | Fuente |
|---|---|---|
| Open ASR Leaderboard, error medio en inglés, Granite Speech 4.1 2B | 5,33 % | Leaderboard, mayo de 2026 |
| Open ASR Leaderboard, Whisper large-v3 | 7,44 % | Leaderboard |
| Parakeet TDT v3 en español: FLEURS / MLS / CoVoST | 3,45 % / 4,39 % / 3,41 % | Ficha del modelo de NVIDIA |
| Diarización, error medio multilingüe: pyannoteAI / DiariZen | 11,2 % / 13,3 % | Estudio independiente, arXiv 2509.26177 |
| Parakeet en un M4 Pro | ~190 veces tiempo real | FluidAudio |

No hay una fuente común que compare Parakeet y Whisper en español. Eso lo
decide el banco de pruebas.

### FluidAudio

Librería Swift con CoreML, Apache 2.0, versión 0.17.5 del 2026-10-01. Corre en
el Neural Engine sin tocar la GPU. Reúne Parakeet, Community-1 con
agrupamiento VBx para ficheros completos, Sortformer, LS-EEND, extracción de
huellas y detección de voz. La usan decenas de apps de Mac de transcripción y
reuniones (Spokenly, Talat, Thoth y otras).

Es la alternativa directa a WhisperKit más SpeakerKit (`argmax-oss-swift`),
que en abierto solo trae Whisper y Community-1; el tiempo real con hablantes
y el vocabulario propio están en Argmax Pro, de pago.

**Matiz para Personas**: su base de voces (`SpeakerManager`) vive en memoria
y solo funciona con la diarización en tiempo real, no con la de ficheros
completos. Para Personas con la mejor calidad, las huellas las guarda Escriba
y la decisión de quién es quién va en `EscribaCore`, como ya plantea
`docs/requisito-hablantes.md`.

### Modelos conjuntos con pesos abiertos

| Modelo | Origen | Licencia | Idiomas | Longitud | En el Mac |
|---|---|---|---|---|---|
| VibeVoice-ASR | Microsoft, enero de 2026, ~9B | MIT | Más de 50 | 60 min de una pasada, con palabras clave | Versión MLX de 4 bits (5,7 GB) vía `mlx-audio`, en Python |
| VibeVoice-ASR-Streaming | Microsoft, septiembre de 2026, 1,5B y 7B | — | 10, con español | Tramos de hasta 8 min | No |
| MOSS-Transcribe-Diarize | OpenMOSS, julio de 2026, 0,9B | Apache 2.0 | Más de 50 | 90 min de una pasada | No: exige GPU de NVIDIA |
| Granite Speech 4.1 2B Plus | IBM | Apache 2.0 | Inglés, francés, alemán, español y portugués | — | No; sirve con vLLM |
| Multitalker Parakeet 0.6B | NVIDIA | — | — | — | No; necesita la salida de Sortformer y una instancia por hablante |

Lo que importa de ellos:

- **Ninguno trae Personas.** Devuelven «hablante 1, hablante 2» dentro de cada
  grabación, sin una huella para reconocerlos en la siguiente. Personas
  seguiría necesitando un modelo de huellas aparte.
- **Solo VibeVoice corre hoy en un Mac, y desde Python.** Integrarlo exige
  portarlo a MLX Swift o lanzar un proceso, y nada en Escriba lanza procesos
  externos (`CLAUDE.md`).
- **Los resultados los publica cada autor.** Todos dicen ganar a Gemini, GPT-4o
  o ElevenLabs. MOSS se mide sobre todo en conjuntos chinos; el 0,9 % de error
  de atribución de Granite es en llamadas telefónicas en inglés entre dos
  personas (Fisher).

## Opciones remotas (referencia, fuera de la dirección)

| Servicio | Lo que destaca |
|---|---|
| AssemblyAI Universal-3.5 Pro | Lidera la diarización en el benchmark de la propia AssemblyAI |
| ElevenLabs Scribe v2 | Hasta 48 hablantes, 99 idiomas |
| OpenAI gpt-4o-transcribe-diarize | Conjunto; acepta clips de 2 a 10 s de hasta 4 personas conocidas y devuelve sus nombres. Mismo endpoint que el resolutor OpenAI de Escriba |
| Mistral Voxtral Mini Transcribe V2 | Conjunto; 13 idiomas con español; 0,003 $ por minuto; febrero de 2026 |
| pyannoteAI Precision-2 | La mejor diarización según pyannote y según el estudio independiente; huellas de voz y API de identificación; solo diariza |
| Deepgram Nova-3, Gladia, Speechmatics | Tuberías clásicas con diarización |
| Gemini | Transcribe con hablantes si se le pide en el prompt |

Error con atribución de hablante (cpWER, menos es mejor), benchmark interno de
AssemblyAI del 2026-09-30:

| Servicio | cpWER |
|---|---|
| AssemblyAI Universal-3.5 Pro | 30,17 |
| ElevenLabs Scribe v2 | 35,26 |
| Gladia | 36,87 |
| Deepgram Nova-3 | 37,92 |

Por qué no es la dirección: la voz sale del Mac, y para Personas eso son
muestras biométricas en un tercero; cada proveedor devuelve los hablantes en
su formato y necesita su adaptador; y el producto se diseña para correr en
local.

## Si se retoma

1. **Banco de pruebas primero** (el de `docs/requisito-hablantes.md`): tres o
   cuatro grabaciones de Rubén con una versión dada por buena. Se mide error
   por palabra contra esa versión, atribución de hablante segundo a segundo,
   tiempo, memoria y tamaño de la descarga.
2. **Candidatos, por orden**:
   - Lo actual: Whisper large-v3 turbo más Community-1.
   - FluidAudio: Parakeet Ultra o v3 más Community-1 con VBx.
   - Sortformer, en las grabaciones de hasta 4 hablantes.
   - VibeVoice-ASR en MLX de 4 bits, solo medido dentro del banco, fuera de la
     app.
3. **Criterio**: se cambia de motor solo si gana con claridad en español en
   esas grabaciones. Cambiarlo reabre la decisión cerrada «WhisperKit es el
   único backend local» del `CLAUDE.md`.
4. **Personas va aparte**: guardar las huellas (paso 1 de
   `docs/requisito-hablantes.md`) vale con cualquier diarización por piezas,
   la actual o la de FluidAudio.

## Fuentes

- FluidAudio: https://github.com/FluidInference/FluidAudio (README y
  `Documentation/Diarization/SpeakerManager.md`, `GettingStarted.md`)
- Argmax OSS Swift: https://github.com/argmaxinc/argmax-oss-swift
- Parakeet TDT 0.6B v3: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Canary-1B-v2 y Parakeet-TDT-0.6B-v3: https://arxiv.org/abs/2509.14128
- Open ASR Leaderboard: https://arxiv.org/abs/2510.06961 y https://benchmarklist.com/benchmarks/open_asr_leaderboard/
- Granite Speech 4.1: https://replicate.com/ibm-granite/granite-speech-4.1-2b/readme
- Granite Speech 4.1 2B Plus: https://www.mixpeek.com/model/ibm-granite/granite-speech-4.1-2b-plus
- Benchmarking Diarization Models: https://arxiv.org/abs/2509.26177
- pyannoteAI, modelos y huellas: https://docs.pyannote.ai/models y https://docs.pyannote.ai/tutorials/identification-with-voiceprints
- pyannoteAI, comparativa 2026: https://www.pyannote.ai/blog/top-7-speaker-diarization-apis-and-models-in-2026
- DiariZen para Apple Silicon: https://github.com/NikiO-INO/diarizen-apple
- VibeVoice-ASR: https://huggingface.co/microsoft/VibeVoice-ASR
- VibeVoice-ASR-Streaming: https://arxiv.org/abs/2609.02812
- VibeVoice en MLX: https://simonwillison.net/b/9432 y https://github.com/Blaizzy/mlx-audio
- MOSS-Transcribe-Diarize: https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize
- Multitalker Parakeet: https://huggingface.co/nvidia/multitalker-parakeet-streaming-0.6b-v1
- AssemblyAI, diarización 2026: https://www.assemblyai.com/blog/top-speaker-diarization-libraries-and-apis
- OpenAI, transcripción con hablantes: https://platform.openai.com/docs/guides/speech-to-text
- Mistral Voxtral Transcribe 2: https://mistral.ai/news/voxtral-transcribe-2
