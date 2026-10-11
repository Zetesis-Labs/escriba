# Escriba para macOS

Aplicación macOS 26 con interfaz React/TypeScript, host Rust, SurrealDB embebida
y adaptadores Apple en Swift. Se instala como **Escriba.app**. El identificador
técnico `dev.zetesis.escriba.tauri` se mantiene para conservar biblioteca,
configuración y permisos al actualizar.

## Construir e instalar

Requiere Rust estable, Node 22.12 o posterior, Bun en la versión de `runtime-host/bun-version` y Xcode con
SDK macOS 26 más el toolchain Swift del repositorio. Desde la raíz:

```sh
./scripts/build-app.sh --dev
./scripts/build-app.sh --release
./scripts/install-app.sh --release
```

El script prepara dependencias fijadas por lockfile, compila los adaptadores,
el runtime TypeScript y la app, y verifica su firma. La aplicación instalada
incluye los ejecutables; no necesita Node, Bun ni npm en el Mac del usuario.
`ESCRIBA_SWIFT_SCRATCH` permite reutilizar una caché de SwiftPM.

## Datos

La biblioteca vive en Application Support bajo el identificador de la app.
`ESCRIBA_TAURI_DATA` permite elegir otra ubicación para pruebas aisladas.
SurrealDB/SurrealKV guarda entidades, versiones, publicaciones, ajustes, memoria,
trazas y trabajos. No se escribe una biblioteca JSON ni SQLite.

### Autorizar carpetas: opción recomendada

En **Ajustes → Carpetas vigiladas**, o en el aviso de acceso, pulsa **Autorizar
carpeta** y selecciónala en el panel de macOS. Para una fuente existente debes
elegir esa carpeta; si se ha trasladado y la ruta anterior ya no existe, puedes
indicar su nueva ubicación conservando su identidad y configuración.
La selección se guarda en SurrealDB mediante un bookmark nativo privado y se
restaura antes de iniciar la vigilancia. Cancelar el panel no cambia los ajustes.
El botón de autorización solo aparece si el escaneo informa un problema de
acceso; no se pide otra vez por faltar un bookmark si macOS ya deja leer la carpeta.

**Acceso total al disco** sigue disponible como alternativa opcional si macOS
impide el acceso por carpeta. El botón abre Ajustes del Sistema: ve a
**Privacidad y seguridad → Acceso total al disco**, añade o activa **Escriba.app** y reiníciala.
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

Las notificaciones usan el centro nativo de macOS y solicitan permiso para
alertas y sonido al arrancar. «Nota transcrita» muestra hasta 80 caracteres del
texto, sin sonido, si está activo «Notificar cada transcripción». Los problemas
se avisan siempre y con el sonido del sistema; el cuerpo se limita a 240
caracteres. Estos avisos de transcripción corresponden al pipeline
automático, no a reprocesar, resumir o publicar a mano.

Las actualizaciones conservan la biblioteca existente. La biblioteca JSON de la
primera versión se convierte al abrirla, conservando ese archivo de origen.

Los tokens introducidos en la app se guardan en archivos privados 0600 y se leen
solo en Rust. Los pesos Whisper instalados se reutilizan desde
`~/Library/Application Support/escriba/models`; las descargas son explícitas y
muestran «Descargando…» con una barra de progreso en STT.
Detalles del esquema: [persistencia](../../docs/tauri-persistence.md).

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

El host observa la memoria residente de cada proceso de receta cada 50 ms y lo
termina al superar 512 MiB; puede haber exceso entre muestras. Aplica además
un presupuesto de 10 s de ejecución activa, excluyendo las esperas de capacidades. Cada
trabajo tiene un límite total de dos horas. El motor de inferencia se retira tras
cinco minutos de inactividad. Véase [runtime](runtime-host/README.md) y
[protocolo Apple](../../docs/tauri-native-protocol.md).

## Funciones

- **Biblioteca:** importación y arrastre, grabación con pausa, reproducción y
  segmentos, hablantes, versiones, correcciones, resúmenes,
  datos, exportación TXT/Markdown/SRT/JSON, descarte y borrado local.
- **Procesamiento:** motores locales Apple y resolutores remotos compatibles
  con OpenAI, diarización local, cancelación, reprocesamiento manual con nueva
  versión y recuperación automática sin repetir inferencias compatibles. La hoja
  de reprocesado permite ajustar los parámetros solo para esa ejecución sin
  cambiar la receta guardada.
- **Recetas:** formularios declarados con Zod, parámetros, preguntas estructuradas,
  delegación, ejecución de prueba y trazas. El playground CodeMirror permite
  editar el proyecto, instalar dependencias, comprobar tipos con TypeScript 7,
  ejecutar pruebas y construir `dist/` con el Bun incluido. También admite un
  editor externo y proyectos distribuidos solo con su `dist/`.
- **Conectores:** cuentas, credenciales, destinos declarados en TypeScript,
  validación, descubrimiento, vista previa, publicación, regeneración y retirada.
  El recibo conserva la cuenta, configuración y programa usados al publicar.
- **Registro:** errores, etapas de trabajos y trazas, incluidas pruebas de recetas.
- **Ajustes:** tema, idioma, modelo, inicio de sesión, notificaciones y
  carpetas Just Press Record, Notas de Voz o cualquier carpeta de audio.
- **macOS:** barra de menús, diálogos nativos, vigilancia FSEvents con reconciliación,
  asentamiento de archivos y materialización de contenido descargable de iCloud.

Las dependencias npm se instalan en el proyecto y se fijan con su lockfile.
Bun empaqueta ESM/CommonJS/JSON; el paquete propio de conectores se proporciona
como dependencia `file:`. Los paquetes deben poder ejecutarse con las capacidades
ofrecidas; las APIs de Node que necesitan disco, procesos o red no se habilitan
por instalar un paquete. Véase [proyectos de recetas](../../docs/proyecto-recetas-tauri.md).

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

Preparar los ejecutables con `build-app.sh` antes del primer test Rust. Las
pruebas usan SurrealKV real, procesos TypeScript compilados, reinicios y
cancelaciones, servidores locales y audios sintéticos. Los
tests Swift del adaptador están en `EscribaNativeHostTests`.

La inferencia local se ha comprobado con el proceso incluido en el bundle:
Whisper transcribió audio sintético con tiempos y Apple Intelligence produjo
un resumen. Las cifras y resultados de entrega se registran en el PR.

El playground también se ha comprobado en la app instalada, con herramientas
encima del editor y apertura de la carpeta en VS Code, a tamaño de ventana mínimo.
Las validaciones manuales pendientes siguen en `docs/pendiente-tauri.md`.
No se han usado Notion real, tokens reales ni servicios STT/LLM externos. Estos
límites de validación no se sustituyen por una biblioteca aislada de desarrollo.
