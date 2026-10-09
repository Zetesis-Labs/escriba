# Escriba para macOS con Tauri

Aplicación macOS 26 con interfaz React/TypeScript, host Rust, SurrealDB embebida
y adaptadores Apple en Swift. Es el destino de la migración decidido por Rubén.
Se instala como **Escriba Tauri.app**, identificador `dev.zetesis.escriba.tauri`,
para conservar la instalación SwiftUI durante la transición.

## Construir e instalar

Requiere Rust estable, Node 22.12 o posterior, Deno 2.6.9 o posterior y Xcode con
SDK macOS 26 más el toolchain Swift del repositorio. Desde la raíz:

```sh
./scripts/build-tauri.sh --dev
./scripts/build-tauri.sh --release
./scripts/install-tauri.sh --release
```

El script prepara dependencias fijadas por lockfile, compila los adaptadores,
el runtime TypeScript y la app, y verifica su firma. La aplicación instalada
incluye los ejecutables; no necesita Node, Deno ni npm en el Mac del usuario.
`ESCRIBA_SWIFT_SCRATCH` permite reutilizar una caché de SwiftPM.

## Datos y migración

La biblioteca vive en Application Support bajo el identificador de la app.
`ESCRIBA_TAURI_DATA` permite elegir otra ubicación para pruebas aisladas.
SurrealDB/SurrealKV guarda entidades, versiones, publicaciones, ajustes, memoria,
trazas y trabajos. No se escribe una biblioteca JSON ni SQLite.

Al abrir una biblioteca Tauri vacía se incorpora automáticamente la biblioteca
de Escriba situada en `~/Library/Application Support/escriba/library`. Se muestra
el progreso de apertura, se conserva el origen y el procesamiento automático
queda pausado para revisar el resultado. La importación se realiza una sola vez;
borrar después las notas no hace que reaparezcan. Los errores se muestran en la
ventana y permiten reintentar. `ESCRIBA_TAURI_DATA` desactiva esta detección para
que las pruebas aisladas no accedan a datos de la instalación normal.

También se recuperan una vez las carpetas vigiladas de las preferencias SwiftUI
si no hay carpetas configuradas en Tauri. Esto repara instalaciones que ya habían
importado la biblioteca sin sus fuentes. Los audios conocidos se enlazan con las
notas importadas y conservan sus versiones y estado, incluidas las descartadas.
La vigilancia incorpora los nuevos audios; **Reanudar procesamiento** en el aviso
de la biblioteca activa la ejecución de las recetas. Si Tauri ya tiene carpetas,
se conserva esa configuración. No se leen credenciales al recuperar las fuentes.

### Autorizar carpetas: opción recomendada

En **Ajustes → Carpetas vigiladas**, o en el aviso de acceso, pulsa **Autorizar
carpeta** y selecciónala en el panel de macOS. Para una fuente existente debes
elegir esa carpeta; si se ha trasladado y la ruta anterior ya no existe, puedes
indicar su nueva ubicación conservando su identidad y configuración.
La selección se guarda en SurrealDB mediante un bookmark nativo privado y se
restaura antes de iniciar la vigilancia. Cancelar el panel no cambia los ajustes.

**Acceso total al disco** sigue disponible como alternativa opcional si macOS
impide el acceso por carpeta. El botón abre Ajustes del Sistema: ve a
**Privacidad y seguridad → Acceso total al disco**, añade o activa **Escriba
Tauri.app** y reiníciala. El permiso de la edición Swift no se traslada a Tauri.
[Guía de Apple sobre Privacidad y seguridad](https://support.apple.com/es-es/guide/mac-help/mchl211c911f/27/mac/27).

Notas de Voz guarda sus audios en un contenedor protegido. Apple demuestra el
acceso a una grabación seleccionada mediante el panel; la vigilancia de toda la
carpeta y su acceso tras reiniciar requieren comprobarse sin Acceso total al
disco en la instalación de destino. Esta versión conserva el empaquetado sin
App Sandbox: seleccionar carpetas no impone aislamiento de todo el sistema de
archivos. [Investigación y límites](../../docs/investigacion-acceso-carpetas-macos.md).

Si una carpeta no se puede leer, la app muestra un aviso persistente y marca el
problema en la barra lateral y en Ajustes. **Autorizar carpeta** es la primera
opción; **Reintentar** vuelve a escanear. También se solicita una notificación
de escritorio cuando cambia el fallo, sin repetirla en cada pasada. El aviso
se retira cuando se recupera el acceso. Los fallos al descargar un audio de
iCloud también aparecen en este aviso.

Si Tauri ya tiene grabaciones o se quiere elegir otra biblioteca, está
**Ajustes → Importar biblioteca SwiftUI**, con un plist de preferencias opcional.
La importación abre SQLite en modo de lectura y copia los audios. Incluye versiones, datos,
publicaciones, memoria de respuestas y trazas. Las cuentas importadas requieren
revisar su configuración y volver a introducir credenciales; el importador nunca
lee tokens ni el Llavero. La biblioteca JSON del primer experimento se migra
al abrirla, conservando ese archivo de origen.

Los tokens introducidos en la app se guardan en archivos privados 0600 y se leen
solo en Rust. Los pesos Whisper instalados se reutilizan desde
`~/Library/Application Support/escriba/models`; las descargas son explícitas.
Detalles del esquema y la importación: [persistencia](../../docs/tauri-persistence.md).

## Responsabilidades

| Lenguaje | Responsabilidad |
| --- | --- |
| TypeScript | Interfaz, formularios Zod, recetas, reglas de procesamiento, resumen por partes, Notion y OKF |
| Rust | SurrealDB, cola y recuperación, permisos, secretos, HTTP, archivos, compilación y supervisión |
| Swift | WhisperKit/SpeakerKit, FoundationModels, captura AVFoundation y materialización iCloud |

La WebView no ejecuta trabajos. Rust conserva la cola y supervisa un proceso
TypeScript compilado; cada programa de receta tiene su propio proceso sin permisos
de archivos, red o subprocesos. Cerrar o recargar una ventana no cancela la cola.
Tras terminar la app, los trabajos interrumpidos se recuperan al arrancar y
reutilizan transcripciones y respuestas compatibles.

El host aplica un límite de heap de 512 MiB al runtime y un presupuesto de 10 s
de ejecución activa por programa, excluyendo las esperas de capacidades. Cada
trabajo tiene un límite total de dos horas. El motor de inferencia se retira tras
cinco minutos de inactividad. Véase [runtime](runtime-host/README.md) y
[protocolo Apple](../../docs/tauri-native-protocol.md).

## Funciones

- **Biblioteca:** importación y arrastre, grabación con pausa, reproducción y
  velocidad, búsqueda, segmentos, hablantes, versiones, correcciones, resúmenes,
  datos, exportación TXT/Markdown/SRT/JSON, descarte y borrado local.
- **Procesamiento:** motores locales Apple y resolutores remotos compatibles
  con OpenAI, diarización local, cancelación, reprocesamiento manual con nueva
  versión y recuperación automática sin repetir inferencias compatibles.
- **Recetas:** formularios declarados con Zod, parámetros, preguntas estructuradas,
  delegación, ejecución de prueba y trazas. Un proyecto se edita externamente y
  se compila con el esbuild incluido en la app.
- **Conectores:** cuentas, credenciales, destinos declarados en TypeScript,
  validación, descubrimiento, vista previa, publicación, regeneración y retirada.
  El recibo conserva la cuenta, configuración y programa usados al publicar.
- **Registro:** errores, etapas de trabajos y trazas, incluidas pruebas de recetas.
- **Ajustes:** tema, idioma, modelo, inicio de sesión, notificaciones, migración y
  carpetas Just Press Record, Notas de Voz o cualquier carpeta de audio.
- **macOS:** barra de menús, diálogos nativos, vigilancia FSEvents con reconciliación,
  asentamiento de archivos y materialización de contenido descargable de iCloud.

Las dependencias npm se instalan en el proyecto y se fijan con su lockfile.
Esbuild acepta ESM/CommonJS/JSON; el paquete propio de conectores se proporciona
como dependencia `file:`. Los paquetes deben poder ejecutarse con las capacidades
ofrecidas; las APIs de Node que necesitan disco, procesos o red no se habilitan
por instalar un paquete.

## Verificación

```sh
cd apps/tauri
npm test
npm run build
npm run typecheck:runtime
cd src-tauri
cargo test --lib
cargo clippy --all-targets -- -D warnings
```

Preparar los ejecutables con `build-tauri.sh` antes del primer test Rust. Las
pruebas usan SurrealKV real, procesos TypeScript compilados, reinicios y
cancelaciones, SQLite sintético, servidores locales y audios sintéticos. Los
tests Swift del adaptador están en `EscribaNativeHostTests`.

La inferencia local se ha comprobado con el proceso incluido en el bundle:
Whisper transcribió audio sintético con tiempos y Apple Intelligence produjo
un resumen. Las cifras y resultados de entrega se registran en el PR.

La inspección visual automatizada sigue bloqueada por la herramienta de acceso a
las apps locales, incluso tras la autorización del usuario. Micrófono y
notificaciones requieren comprobación interactiva de macOS.
No se han usado Notion real, tokens reales ni servicios STT/LLM externos. Estos
límites de validación no se sustituyen por los datos de muestra (`?demo=1`).
