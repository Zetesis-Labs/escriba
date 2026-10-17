# Escriba en Windows

Adaptación de escritorio para Windows 11 x64, con la misma biblioteca, recetas,
conectores y protocolo nativo de macOS y Linux. El identificador persistido sigue
siendo `dev.zetesis.escriba.tauri`.

## Motores y datos

Whisper se ejecuta localmente mediante whisper.cpp y `whisper-rs`. El modelo de
serie es `large-v3-turbo`; el catálogo también ofrece tiny, base, small, medium
y large-v3. Los modelos se descargan explícitamente desde STT y se guardan en
`%LOCALAPPDATA%\escriba\models`. La transcripción no descarga modelos.

La diarización usa sherpa-onnx, Pyannote segmentation 3.0 y NeMo TitaNet small,
compartiendo implementación, modelos y umbral de reconocimiento con Linux. Los
modelos de hablantes se descargan junto con Whisper. La grabadora usa WASAPI
mediante cpal y conserva las capturas en Opus/Ogg. Importar acepta los formatos
de audio del catálogo existente.

No se incluye un LLM. Para resumir o preguntar se configura un resolutor
compatible con OpenAI, remoto o alojado por el usuario. Una receta que necesita
un LLM sin haber elegido uno muestra el problema y conserva la transcripción.

La distribución habitual usa CPU. `-Cuda` construye Whisper con CUDA cuando el
equipo de desarrollo tiene el toolkit de NVIDIA; requiere validar y distribuir
sus dependencias antes de ofrecer esa variante.

La biblioteca nueva se guarda en el directorio de datos de la aplicación del
usuario. `ESCRIBA_TAURI_DATA` selecciona una biblioteca aislada de pruebas. La
carpeta privada usa una DACL protegida para su propietario y SYSTEM; sus archivos
heredan esa protección. Las credenciales permanecen fuera de la interfaz y de
los procesos de recetas.

## Recetas y herramientas

`escriba-sandbox.exe` arranca los procesos en AppContainer y los incorpora a un
Job Object antes de reanudarlos. Una receta recibe solo los canales de protocolo,
sin capacidades de red ni autorización de carpetas. El Job Object limita memoria
y procesos y termina el hijo al cerrarse el supervisor.

Las herramientas del proyecto tienen un contenedor propio por carpeta y perfil:
pueden modificar el proyecto y leer las dependencias incluidas. Solo instalar
dependencias concede salida a internet; se mantienen desactivados sus scripts de
instalación. La edición desde la aplicación bloquea los directorios durante cada
operación y rechaza uniones, enlaces, rutas de escape, nombres reservados y
flujos alternativos de NTFS.

El lanzador externo generado es `escriba.cmd`, con las acciones `install`,
`check`, `test` y `build`. El playground utiliza el Bun y el TypeScript nativo
incluidos, también cuando el usuario no tiene herramientas de desarrollo.
Los paquetes de tipos incluidos se instalan en la raíz del proyecto; sus
manifiestos preparados evitan las copias anidadas de dependencias locales que
fallan con Bun en Windows sin permisos para crear enlaces simbólicos.

## Construir

En el equipo de desarrollo:

- Visual Studio Build Tools 2022 con C++ y SDK de Windows.
- Rust estable con `rustfmt` y `clippy`.
- Node 24 o posterior con npm y el Bun fijado en
  `apps/tauri/runtime-host/bun-version`.
- CMake, NASM y LLVM. `LIBCLANG_PATH` puede señalar la carpeta que contiene
  `libclang.dll` si no está en `C:\Program Files\LLVM\bin`.

Desde PowerShell, en la raíz:

```powershell
./scripts/build-windows.ps1
./scripts/test-windows.ps1
```

El primer comando prepara dependencias, host de audio, sandbox, controlador y
aplicación y genera el instalador NSIS en
`apps/tauri/src-tauri/target/release/bundle/nsis/`. Incluye ejecutables,
bibliotecas nativas y herramientas; el usuario final no necesita Rust, Python,
Node, Bun ni WSL. NSIS instala para el usuario actual.

`-SkipDependencies` reutiliza las dependencias ya instaladas; `-NoBundle`
construye sin generar instalador y `-PrepareOnly` prepara los motores para las
pruebas. `-DebugBuild` selecciona la compilación de desarrollo.

## Verificación

Las pruebas se hacen con bibliotecas temporales y audio sintético. La batería
común del host, las pruebas de Windows y las de motores locales corren con:

```powershell
cargo test --release --manifest-path apps/tauri/native-host/Cargo.toml
cargo test --release --manifest-path apps/tauri/sandbox/Cargo.toml
```

La prueba de inferencia real requiere las voces de prueba Microsoft Helena
Desktop y Microsoft Zira Desktop y descarga tiny y los modelos de hablantes:

```powershell
./scripts/test-windows.ps1 -Inference
```

La CI de Windows construye el instalador y ejecuta las suites sin micrófono ni
cuentas externas. Las pruebas de enlaces simbólicos Unix permanecen en sus
plataformas; Windows añade pruebas con uniones de directorios que no requieren
activar el modo de desarrollador.

El 2026-10-17 se reprodujo con Node 22.23.3 un fallo al abrir la copia de una
biblioteca en una ruta con «ñ». El mismo caso pasa con Node 24.19.0; por eso
Windows fija Node 24 para construir y comprobar. El runtime distribuido es Bun,
y no utiliza el Node del equipo.

## Comprobaciones locales del 2026-10-17

- Host de audio en release: 52 pruebas correctas. Las dos pruebas adicionales
  de inferencia real también pasan: voz sintética en WAV y Opus, diarización
  de dos voces y comparación de sus huellas.
- Sandbox: tres pruebas unitarias y una prueba real de AppContainer que
  comprueba acceso a archivos, escritura, red y creación de subprocesos.
- Aplicación Rust: 127 pruebas correctas, con RocksDB real, edición de archivos,
  bloqueo de uniones y ejecución de las herramientas incluidas.
- TypeScript: 598 pruebas correctas y seis omitidas; comprobación de tipos del
  runtime y construcción de la interfaz correctas.
- `rustfmt` y Clippy sin advertencias para los tres crates. El host también
  construye en modo de desarrollo.
- Whisper `large-v3-turbo` transcribe un WAV sintético de 13,7 segundos en
  español con diarización local. La distribución comprobada utiliza CPU.
- Instalador NSIS instalado en una carpeta con espacios y «ñ»: los tres
  motores coinciden con los construidos y el ejecutable principal solo cambia
  en el marcador de empaquetado que añade Tauri. Desde esa instalación pasan
  la transcripción y diarización reales y la reapertura de una biblioteca con
  «ñ», conservando su nota y versión anteriores a la actualización.
- La interfaz Tauri abre la biblioteca en Windows. El control de pantalla se
  interrumpió con Escape; la comprobación posterior del paquete y de los
  motores se hizo automáticamente, sin manejar la interfaz.

La ejecución en CI remota y las regresiones en macOS/Linux requieren sus
respectivos entornos. CUDA y el micrófono físico no forman parte de estas
pruebas. La aceptación manual de Rubén permanece separada de esta verificación.
