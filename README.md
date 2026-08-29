# jpr-transcribe

Transcribe automaticamente las notas de voz de **Just Press Record** con el CLI de
**MacWhisper**. No toca la app ni cambia como grabas: tu sigues pulsando el boton
en el iPhone, el Watch o el Mac, y el texto aparece solo.

Swift puro, sin dependencias externas. Un binario y un LaunchAgent.

## Por que no se leen las transcripciones de la propia app

Just Press Record no las expone. Su unica superficie programable son tres App
Intents de control — `StartRecordingIntent`, `StopRecordingIntent`,
`ToggleRecordingIntent` — sin entidades ni queries: se le puede decir que grabe,
pero no se le puede pedir nada. Tampoco tiene AppleScript (es una app Catalyst),
su URL scheme `justpressrecord://` no acepta verbos, y su extension solo recibe
audio de entrada.

Lo que si es accesible es el audio en iCloud Drive:

    ~/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents/
    └── YYYY-MM-DD/HH-MM-SS.m4a

Esa carpeta es la API de facto, y es sobre la que trabaja este proyecto.

## Que hace que sea fiable

Una grabacion que llega del movil no aparece como un fichero normal. Estas son
las trampas y como se manejan:

- **Placeholders de iCloud.** El fichero puede existir sin contenido, marcado
  `SF_DATALESS` en `st_flags`. Se detecta por el flag y se materializa leyendolo.
  (`brctl status` ya no sirve: devuelve `BRCloudDocsErrorDomain:30` con el
  FileProvider moderno. `NSMetadataQuery` tampoco, porque consulta el contenedor
  iCloud de la propia app y no tenemos su entitlement.)
- **Escritura progresiva.** Una grabacion en curso crece. Solo se transcribe
  cuando lleva quieta `settleSeconds` (15 s).
- **Eventos perdidos.** Si el Mac duerme o el agente esta caido cuando llega la
  grabacion, el evento FSEvents no existe al despertar. Por eso el watcher solo
  *despierta* al bucle: cada ciclo re-escanea el disco y lo compara contra el
  ledger. Es idempotente y se auto-reconcilia, ademas de barrer cada 5 minutos
  aunque no haya eventos.
- **Ritmo adaptativo.** Si algo quedo esperando a asentarse, el siguiente ciclo
  es a los 10 s, no a los 5 minutos. Sin esto una grabacion recien llegada se
  quedaba parada hasta la siguiente reconciliacion.
- **MacWhisper debe estar vivo.** `mw` es un cliente delgado que habla por socket
  con la app; si no corre, se lanza en background (`open -gj`) y se espera.
- **Reintentos acotados.** Un fallo se reintenta pasados 10 minutos, hasta 5 veces,
  y queda registrado con su motivo en `status`.
- **Una sola instancia a la vez.** Un `flock` sobre
  `~/.local/state/jpr-transcribe/instance.lock` impide que la app y el CLI (o dos
  copias de la app) trabajen sobre el mismo ledger y transcriban por duplicado.
  El segundo en llegar se niega e identifica al que tiene el lock. `status` no
  necesita el lock: es solo lectura.
- **Una carpeta ilegible no se confunde con una carpeta vacia.** Si falla la
  lectura se reporta como error con la pista del Acceso total al disco, en vez de
  parecer que simplemente no hay nada que hacer.

### Ritmo

| Situacion | Cadencia |
|---|---|
| Aparece o cambia un `.m4a` | inmediato (FSEvents + 3 s de estabilizacion) |
| Algo esperando a asentarse o a bajar de iCloud | cada 10 s |
| Todo tranquilo | cada 5 min (barrido de seguridad) |

Latencia medida de punta a punta: **~25 s** desde que el fichero aparece hasta que
el texto esta escrito (15 de ellos son el asentamiento deliberado).

En reposo la app ocupa **13 MB** de memoria fisica y 0 % de CPU: no carga ningun
modelo, el trabajo pesado lo hace MacWhisper solo cuando hay algo que transcribir.

## La app de barra de menus

`JPR Transcribe.app` es una app sin ventana ni icono en el Dock (`LSUIElement`)
que **sustituye al LaunchAgent**: ella misma es el vigilante. Desde la barra de
menus se ve el estado, las ultimas transcripciones (clic para abrirlas), el
recuento y las acciones.

Existe sobre todo porque un demonio invisible que deja de funcionar es el peor
modo de fallo posible para unas notas en las que confias. El icono cambia segun
el estado y las notificaciones avisan de cada transcripcion (sin sonido) y de
cualquier problema (con sonido).

    ./scripts/build-app.sh      # construye .build/app/JPR Transcribe.app
    ./scripts/install-app.sh    # la instala en /Applications

`install-app.sh` solo recompila la app. Si tambien quieres el CLI actualizado,
lanza `swift build -c release` aparte.

Como la firma es ad-hoc, reinstalar puede invalidar el Acceso total al disco
concedido: si tras una reinstalacion aparece "no puedo leer la carpeta",
vuelve a concederselo.

Despues:

1. **Acceso total al disco** para `JPR Transcribe` en Ajustes > Privacidad y
   seguridad, o no podra leer `~/Library/Mobile Documents`.
2. **Arranque automatico**: Ajustes > General > Elementos de inicio > +.

El registro va a `~/Library/Logs/jpr-transcribe.log` ("Ver registro" en el menu).

## Uso desde terminal

El CLI sigue existiendo y comparte el mismo ledger que la app (no los ejecutes
a la vez apuntando a la misma carpeta).

    swift build -c release
    .build/release/jpr-transcribe status    # que hay en disco y que se transcribio
    .build/release/jpr-transcribe once      # una pasada y salir
    .build/release/jpr-transcribe watch     # se queda vigilando

### Como servicio

    ./launchd/install.sh      # compila, instala en ~/.local/bin y carga el agente
    tail -f ~/Library/Logs/jpr-transcribe.log
    ./launchd/uninstall.sh

> **Acceso total al disco**: launchd arranca el agente fuera de la sesion de
> Terminal, asi que hay que concederselo a `~/.local/bin/jpr-transcribe` en
> Ajustes > Privacidad y seguridad. Sin eso no puede leer `~/Library/Mobile Documents`.

## El backend de transcripcion es un puerto

`Pipeline` no conoce MacWhisper. Recibe un `TranscriptionBackend`, que es una
struct de funciones —`transcribe` y `preflight`— igual que `Sink`. MacWhisper es
una implementacion (`MacWhisperBackend.make(...)`), no el unico camino posible.

Se invoca a `mw` con `--format json`, asi que cada transcripcion llega como un
`Transcript` con segmentos, tiempos de inicio y fin, tiempos por palabra y, si la
diarizacion esta activa, el hablante de cada segmento. El texto plano sigue
disponible en `transcript.text`.

    jpr-transcribe once --speakers    # detecta hablantes en esta pasada

## Backends de transcripcion

| Backend | Como | Diarizacion |
|---|---|---|
| `macwhisper` (por defecto) | CLI `mw`, necesita la app de MacWhisper viva | `--speakers` |
| `whisperkit` | CoreML sobre el Neural Engine, sin apps de terceros | SpeakerKit (pyannote v4) |

    jpr-transcribe download                      # trae el modelo de WhisperKit
    jpr-transcribe once --backend whisperkit     # transcribe sin MacWhisper
    jpr-transcribe once --backend whisperkit --speakers

WhisperKit guarda su modelo en `~/Library/Application Support/jpr-transcribe/models`
y se lo descarga el solo: no depende de que MacWhisper lo haya bajado antes, o
no arrancaria en un Mac limpio. SpeakerKit hace lo propio con los suyos.

Medido sobre 26 grabaciones reales, la divergencia entre ambos backends es del
**6,45%** y es sobre todo de estilo: MacWhisper segmenta fino y conserva las
dudas del habla, WhisperKit agrupa en frases y las limpia. Ninguno gana al otro
de forma consistente.

Cuando hay diarizacion, la salida agrupa por interlocutor:

    Speaker 1: Quiero proponer una cosa.
    Speaker 2: Cuentame.

**WhisperKit y SpeakerKit son CoreML**: macOS y iOS, ni Windows ni Linux. Si
algun dia hicieran falta, el equivalente multiplataforma es sherpa-onnx, que
trae transcripcion y diarizacion, y el puerto permite anadirlo sin tocar el
resto.

## Modelo de transcripcion

El modelo esta **fijado explicitamente** en `Transcriber.defaultModel`:

    whisperkit:openai_whisper-large-v3-v20240930   (Large v3 Turbo)

Se clava a proposito. Si se dejara sin especificar, `mw` usaria el que este
seleccionado en la interfaz de MacWhisper, y cambiarlo alli cambiaria en silencio
la calidad de todas tus transcripciones. Asi es reproducible.

Al arrancar se comprueba que sigue instalado; si no lo esta, la app avisa con una
notificacion y `status` lo marca como `NO INSTALADO`. Para cambiarlo puntualmente:

    jpr-transcribe --model parakeet-pro:nvidia_parakeet-v3_494MB once

El idioma tambien esta fijo (`--language es`). Fijarlo da mejor precision que
`auto`, a cambio de forzar el castellano en una grabacion en otro idioma.

## Destino de las transcripciones

Por defecto escribe `~/Documents/Transcripciones JPR/YYYY-MM-DD/HH-MM-SS.txt`.

El destino es un punto de extension: `Sink` es un simple
`(Recording, Transcript) throws -> URL`. Cambiar de destino es escribir otra
funcion y pasarla al `Pipeline`. El sink por defecto escribe solo
`transcript.text`; los segmentos estan disponibles para destinos mas ricos.

## Estructura

| Modulo | Que hay |
|---|---|
| `JPRCore` | Nucleo puro: parseo de rutas, clasificacion de estado, seleccion de pendientes, ritmo del bucle, modelo `Transcript`. Sin I/O, cubierto por tests. |
| `JPRKit` | Cascara: FSEvents, stat y materializacion, ledger SQLite, backends de transcripcion, orquestacion. |
| `jpr-transcribe` | CLI. |
| `JPRMenuBar` | App de barra de menus: estado, notificaciones y acciones. |

    swift test
