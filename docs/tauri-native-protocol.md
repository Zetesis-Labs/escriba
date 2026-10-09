# EscribaNativeHost: protocolo nativo v1

`EscribaNativeHost` es un proceso auxiliar persistente de macOS. Recibe una petición JSON UTF-8 por línea de `stdin` y escribe exactamente una respuesta JSON por línea de `stdout`. Atiende las peticiones en orden; el cliente debe correlacionar por `id`. Mensajes de diagnóstico y salidas de bibliotecas nativas van a `stderr`. El proceso termina al cerrar `stdin`.

Petición: `{"id":"r1","method":"status","params":{}}`. `id` es un texto no vacío y `params` es siempre un objeto. Respuesta correcta: `{"id":"r1","result":{...}}`. Error: `{"id":"r1","error":{"code":"invalid_params","message":"..."}}`. Si el JSON no permite recuperar `id`, se devuelve `null`. Un error de petición no detiene el proceso. El cliente debe tratar `code` como estable y `message` como texto para mostrar o registrar. `backend_unavailable` identifica un modelo Whisper ausente o Apple Intelligence no disponible; el host Rust lo convierte en un trabajo reintentable.

| Método | Parámetros | Resultado |
| --- | --- | --- |
| `status` | `model?:string` | `{protocolVersion:1,whisper:{available:boolean,model:string,modelsPath:string},llm:{available:boolean,reason:string\|null,capacity:number}}`. La disponibilidad corresponde a la variante solicitada; `capacity` indica el máximo de caracteres del resumidor local. |
| `audioInfo` | `audioPath:string` | `{duration:number}` en segundos |
| `fileStatus` | `path:string` | `{size:number,blocks:number,flags:number,dataless:boolean,modifiedAt:string}`. Usa `lstat`; rechaza symlinks y rutas ausentes. `dataless` refleja `SF_DATALESS` de macOS sin abrir el audio. |
| `materialize` | `path:string`, `timeoutSeconds?:number` (1–300, 300 de serie) | `{ready:boolean,dataless:boolean,size:number}`. Solicita a macOS la descarga y lee un byte en una cola auxiliar con tiempo límite. |
| `transcribe` | `audioPath:string`, `model?:string`, `language?:string\|null`, `diarize?:boolean`, `speakers?:number\|null` | `{text:string,segments:[{start:number,end:number,text:string,speaker:string\|null,words:[{start:number,end:number,text:string}]}],voices:[{speaker:string,embedding:number[],model:string}],language:string,duration:number}`. `voices` está vacío si no hay huellas. |
| `diarizedVoices` | `audioPath:string` | `{voices:[{speaker:string,embedding:number[],model:string}],spans:[{speaker:string,start:number,end:number}]}`. Diariza el audio para registrar una voz sin crear una transcripción. |
| `summarize` | `instructions:string`, `prompt:string` | `{title:string,summary:string,tags:string[]}` |
| `ask` | `instructions:string`, `prompt:string`, `schema?:object` | Valor JSON generado; `schema` es JSON Schema de objeto aceptado por `answerSchema(from:)`. Sin esquema, el valor es un texto. |
| `downloadModel` | `model?:string` | `{model:string,path:string}` al terminar la descarga. El modelo por defecto es el de `WhisperKitBackend`. |
| `recordingStart` | `outputPath:string` | `{audioPath:string}`. Pide permiso de micrófono y graba AAC mono a 48 kHz; rechaza sobrescribir un fichero. |
| `recordingStatus` | ninguno | `{active:boolean,paused:boolean,audioPath:string\|null,duration:number}`. Permite restaurar la UI tras recargarla mientras vive el proceso auxiliar de captura. |
| `recordingPause` / `recordingResume` | ninguno | `{audioPath:string,duration:number}` |
| `recordingStop` | ninguno | `{audioPath:string,duration:number}` |

`duration`, `start` y `end` son segundos. `language` toma `"es"` si se omite; `null` o `"auto"` activan la detección automática de WhisperKit. La respuesta indica `"auto"` cuando se solicitó detección: el tipo `Transcript` del núcleo no comunica el idioma detectado. Un idioma explícito debe ser un código de dos o tres letras minúsculas. `speakers` omitido o `null` no fija el número de hablantes; un valor explícito debe ser un entero positivo. `model` se restringe a nombres de variante sin separadores de ruta. `status` consulta la instalación de esa variante sin descargarla. `transcribe` solo usa modelos ya instalados; `downloadModel` es la operación explícita que puede descargar pesos. El motor Whisper se conserva entre peticiones del mismo modelo e idioma y aplica su descarga de memoria por inactividad. La grabadora permite una sesión activa por proceso.

Las huellas (`embedding`) cruzan únicamente el tubo privado entre este proceso y Rust. Rust las guarda y las quita de cualquier respuesta a la WebView o al runtime de recetas; nunca llegan a JavaScript, conectores ni exportaciones. Los tramos de `diarizedVoices` identifican al hablante con el mismo nombre que su huella (`Speaker N`).

El proceso solo contiene las capacidades nativas de audio, WhisperKit/SpeakerKit y FoundationModels. La aplicación Tauri conserva biblioteca, configuración, recetas, conectores y orquestación en TypeScript/Rust. El supervisor Rust descarga el proceso de inferencia después de cinco minutos sin peticiones completas, sin interrumpir una petición en curso.

Rust mantiene la decisión de asentamiento, el seguimiento de carpetas y la persistencia. Su `watcher::file_status` consulta `lstat` y `SF_DATALESS` directamente para no bloquear el escaneo detrás del proceso de materialización; devuelve `modifiedAt` en segundos UNIX. El método nativo `fileStatus` permanece para consultas aisladas y para verificar el resultado de `materialize`. Rust llama a `materialize` solo si aparece `dataless`; si no termina a tiempo, reintenta en una reconciliación posterior. Las peticiones de materialización usan un proceso auxiliar separado del de inferencia para que una descarga iCloud no bloquee la transcripción. La vigilancia por FSEvents despierta el escaneo y un sondeo periódico lo reconcilia tras eventos perdidos o carpetas temporalmente inaccesibles.

Cada carpeta vigilada conserva `style`: `any` (predeterminado, audio recursivo), `justPressRecord` (solo `AAAA-MM-DD/HH-MM-SS.m4a` a un nivel de la raíz, fecha de inicio obtenida del nombre en hora local) o `voiceMemos` (solo audio en el primer nivel, fecha de modificación e identidad estable de inode ante renombrados). El escáner Rust entrega título, fecha e identidad de origen al almacén. Omite symlinks, elementos ocultos y placeholders `.icloud` hasta que aparezca el archivo de audio visible; mantiene la conciliación periódica.

## Verificación de la receta con el motor real

La suite normal comprueba el recorrido de la receta TypeScript compilada a Rust
y Swift con un modelo inexistente. Debe llegar a `backend_unavailable`, sin
descargarlo: un error de parámetros como rechazar `speakers: null` hace fallar
la prueba. Rust usa el mismo método de transcripción en la app y en esta prueba.

La comprobación completa requiere Whisper y Apple Intelligence ya disponibles:

```sh
cargo test --manifest-path apps/tauri/src-tauri/Cargo.toml --lib \
  scripts::tests::receta_predeterminada_transcribe_y_resume_con_motores_locales \
  -- --ignored
```

Genera audio sintético con `say`, ejecuta la receta por defecto en los procesos
reales y reabre una biblioteca SurrealKV temporal. Exige transcripción con
segmentos y duración, título y resumen persistidos. No configura cuentas ni
destinos, no utiliza grabaciones personales y no descarga modelos. Se excluye
del CI ordinario porque depende de los modelos locales de Apple.
