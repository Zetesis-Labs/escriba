# Escriba

Biblioteca de notas de voz para macOS 26. Es un producto OSS (MIT): cada usuario
configura sus resolutores, cuentas y carpetas desde la aplicación.

## Producto y alcance

Desde el 2026-10-10 hay una sola aplicación de escritorio: **Escriba.app**.
La interfaz es React/TypeScript sobre Tauri, el controlador Bun abre la
biblioteca SurrealDB embebida, Rust conserva la cáscara y el conocimiento, y
Swift adapta las APIs de Apple. Los ADR-0005 y ADR-0011 registran estas decisiones.
El identificador técnico `dev.zetesis.escriba.tauri` permanece estable para
conservar biblioteca, permisos y configuración. No renombrar identificadores
persistidos ni directorios de datos como parte de un cambio de presentación.

La referencia de paridad es `git show 2e8614b:<ruta>`. Para continuar la
estabilización, leer `docs/pendiente-tauri.md`, `docs/paridad-swift-tauri.md` y
`docs/auditoria-decisiones-tauri.md`. El cambio a una única app no da por
superadas las comprobaciones técnicas o manuales pendientes.

Las ampliaciones aprobadas incluyen proyectos TypeScript con dependencias npm,
`dist/` como contrato, herramientas Bun incluidas, comprobador TypeScript 7
nativo en Go y playground CodeMirror con apertura en VS Code. Su contrato está
en `docs/proyecto-recetas-tauri.md`. Otros cambios de producto requieren encargo;
no añadir opciones ni flujos aprovechando una corrección.

La UI usa controles propios en `apps/tauri/src/mac/` y menús, alertas y diálogos
nativos. Mantener los textos y flujos acordados: sin búsqueda ni velocidad de
reproducción, React Aria o shadcn. Los filtros visuales por entidades y las
consultas SurrealQL, ambos guardables bajo Biblioteca, están aprobados en
`specs/escriba/filtros-biblioteca/functional-specs.md`.

## Límites de módulos

- **TypeScript/Bun:** interfaz, formularios Zod, recetas, conectores, biblioteca
  SurrealDB/RocksDB, versiones, cola duradera, recuperación, credenciales,
  transporte HTTP y reglas de procesamiento.
- **Rust:** conocimiento en su propia base SurrealDB/RocksDB, permisos,
  archivos, captura y supervisión de procesos.
- **Swift:** WhisperKit/SpeakerKit, FoundationModels, captura AVFoundation y
  materialización de iCloud. `EscribaNativeHost` es el adaptador nativo, no otra app.
- **CLI Swift:** conserva sus módulos portables y su almacenamiento. Sus reglas
  de ledger/SQLite pertenecen al CLI; el escritorio usa la cola de SurrealDB.

La WebView muestra estado y envía acciones; los trabajos sobreviven a cerrar
una ventana. El controlador TypeScript y cada receta usan procesos separados.
Bun ejecuta las recetas aisladas por proceso: `sandbox-exec` en macOS y
`escriba-sandbox` (Landlock y seccomp) en Linux, en `src-tauri/src/confinement.rs`. Tokens,
rutas de audio y huellas no cruzan a código de recetas. Consultar
`apps/tauri/CONTRACT.md`, `apps/tauri/runtime-host/README.md`,
`docs/tauri-persistence.md` y `docs/tauri-native-protocol.md` al tocar esos límites.

Las decisiones puras viven en módulos de dominio con pruebas; la cáscara ejecuta
I/O. En TypeScript usar `src/core/` y `tests/core/`; en Rust, módulos pequeños,
estructuras y errores tipados. Evitar JSON genérico donde se conoce el contrato.
Sin comentarios salvo un porqué no obvio de una línea.

## Datos y pruebas

SurrealDB confirma entidades, versiones, huellas y trabajos transaccionalmente.
Las conversiones de formatos anteriores de la propia biblioteca conservan el
origen y fallan de forma visible ante corrupción; nunca abrir vacía una base que
no se ha podido leer. Preservar la lectura de datos ya guardados al actualizar.

- Nunca publicar notas de voz reales en Notion. Las pruebas contra Notion real
  requieren un encargo de Rubén y usan audio sintético y una base de pruebas.
- Nunca imprimir texto de notas reales en logs, salidas de comandos ni PRs. Para
  inspeccionar datos, cerrar la app, copiar `library.rocksdb` a un temporal y
  extraer sólo recuentos, estados e ids.
- Credenciales en archivos privados 0600; el controlador las inyecta en el transporte. El
  usuario aporta su token de Notion, sin OAuth ni backend de credenciales.
- Las huellas biométricas permanecen en el controlador Bun y en el Mac. La interfaz obtiene
  metadatos, nombres y reconocimientos; ni recetas, conectores ni exportaciones
  reciben vectores.
- Probar persistencia con RocksDB real, procesos reales, servidores locales
  falsos y audios sintéticos. No confundir una demo con validación instalada.
- Una sección está validada cuando Rubén la confirma en pantalla. Instalar y
  avisar al terminar cada apartado; no reinstalar mientras prueba sin avisar.
- Sin push, merge ni cambios en PRs salvo petición de Rubén. Commits
  convencionales en castellano, sin trailers de IA.

## Reglas del producto

- Una receta por defecto procesa lo que entra; elegir otra al grabar o importar
  sólo afecta a esa nota. De serie hay cuatro, todas elegibles: Transcribir,
  Resumir, Publicar y «Por defecto», que se compone en su código con las tres
  (`recetas/piezas.ts`); un proyecto nuevo recibe esa misma composición. No
  hay receta por carpeta, ni exportación/importación de recetas sueltas, ni
  conversión automática de formulario a código.
- Los formularios proceden de `buildRecipeForm(listas)` y Zod. Guardan los valores
  modificados. Un valor que deja de ser válido falla nombrando el campo.
- El proyecto se carga desde `dist/`; construir empaqueta sus dependencias.
  Conservar archivos del usuario y el último artefacto válido si falla un build.
- STT y LLM son listas de resolutores sin favorito. Whisper y Apple Intelligence
  son locales de serie; los remotos hablan una API compatible con OpenAI.
  Una receta sin selección usa el local. Un fallo remoto no cambia de motor.
- Una receta trabaja sobre una nota: copia de la versión que la nota tenía
  abierta al encolar el trabajo (`escriba.nota`) o de la que pida. Lo que
  cambia sustituye su parte; al `guardar()` queda una versión nueva que hereda
  de su origen lo demás y pasa a vigente, o con `editar` cambia esa misma.
  Sin cambios no crea versión. Componer es pasarse la misma nota. Con los
  criterios de la versión de origen, transcribir no vuelve a transcribir.
  Reintentos y Relanzar parten de la misma versión. La memoria es de la
  grabación. La transcripción se guarda antes de resumir. Un resumen vacío es
  un error; si falla el resumen, la nota transcrita se conserva y el fallo se
  muestra.
- El resumen pertenece a la versión y se hereda en las derivadas. «Resumir»
  de la nota lanza la receta Resumir sobre la versión abierta, que guarda una
  versión nueva. Corregir o quitar un resumen regenera las publicaciones
  existentes usando su programa y recibo.
- Los proveedores Notion/OKF viven en `packages/conectores`. Bun aporta
  capacidades genéricas; no duplicar plantillas ni decisiones de proveedor.
  Los errores de publicación se registran y se propagan; la receta decide si
  continuar. Una creación incierta se reconcilia antes de intentar crear otra.
- Descartar conserva una lápida para que la vigilancia no reincorpore el audio.
  El borrado local respeta el archivo original y los servicios externos.
- Diarización desactivada de serie y sólo local. Guardar los hablantes detectados
  sin adivinar cuántos hay; la corrección es explícita. Personas aprende N
  huellas por persona, compara con el mismo modelo y su umbral (0,30 en
  SpeakerKit) y reconoce sólo al transcribir. Registrar voz exige 30 segundos
  de habla; admite micrófono y archivo. Una versión diarizada sin huellas se
  vuelve a diarizar.
- WhisperKit es el motor local; modelos en
  `~/Library/Application Support/escriba/models`, descargados explícitamente.
  Cada modelo añadido en STT es un resolutor local con su modelo; el de serie se
  quita donde hay catálogo y la receta sin STT usa el primer Whisper local
  (`specs/escriba/modelos-whisper/functional-specs.md`).
  Descarga completa sólo con los tres `.mlmodelc` y sus `coremldata.bin`.
  El motor se descarga de memoria tras cinco minutos sin trabajo.

## Construir y comprobar

Compilar en macOS con el SDK de Apple; el devcontainer de ZetesisPortal no aplica
al repositorio. Trabajo en Linux: este bloque es de macOS; seguir
`docs/plan-linux.md`. Usar Node >=22.12 y el Bun fijado en
`apps/tauri/runtime-host/bun-version`, también al ejecutar las pruebas de runtime.

```bash
export TOOLCHAINS=org.swift.640202609131a
./scripts/build-app.sh --release
./scripts/install-app.sh --release
npm test --prefix apps/tauri
npm run typecheck:runtime --prefix apps/tauri
cargo test --manifest-path apps/tauri/src-tauri/Cargo.toml --lib
cargo clippy --manifest-path apps/tauri/src-tauri/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path apps/tauri/src-tauri/Cargo.toml --check
swift test
```

El instalador requiere la app cerrada, verifica la firma, conserva un backup y
revierte la sustitución si falla. La firma estable del Llavero que contiene
«Escriba» conserva permisos entre instalaciones; ad-hoc es sólo respaldo.
`swift build --show-bin-path` da el destino de SwiftPM: no hardcodearlo.

## Swift nativo y CLI

`EscribaCore` contiene modelo y decisiones puras; `EscribaEngine`, puertos de
funciones y orquestación. Swift compila solo en macOS desde el 2026-10-12
(ADR-0007): sin jobs de Linux ni WASI y sin recetas en Swift; las recetas solo
corren en el runtime Bun. `EscribaSystemKit` aporta sistema, vigilancia y
ledger del CLI; `EscribaStore`, su biblioteca GRDB, que conserva el modelo de
trazas de recetas para leer lo ya guardado. Whisper e Intelligence encapsulan
las dependencias de inferencia.

- Puertos como structs de funciones, sin protocolos ni herencia. Core y Engine
  no importan dependencias externas ni APIs de I/O; éstas van al host.
- Swift 6 con concurrencia estricta y errores tipados. Swift 6.4 de swift.org;
  mínimo macOS 26.0, sin APIs de stdlib que exijan un runtime posterior.
- Pruebas `swift-testing`, nombres de comportamiento en castellano. Probar los
  cambios de decisiones antes de su implementación.
- `WhisperKit` no es Sendable: aislar en actor. Captura y APIs Apple respetan su
  aislamiento; nada de Combine ni `@unchecked Sendable` para saltárselo.
- `skipSpecialTokens` debe activarse. El texto diarizado viene de `speakerWords`
  y requiere `wordTimestamps`. SpeakerKit recibe PCM mono a 16 kHz.
- `SystemLanguageModel.availability` puede indicar pesos aún no descargados.
  FoundationModels tiene ventana limitada: el adaptador limita salida, el
  motor trocea y reduce en cascada. No eliminar `maximumResponseTokens`.
- En CLI, ledger decide pendientes y biblioteca guarda versiones. No ejecutar
  dos procesos sobre el mismo ledger; conservar bloqueo y reintentos.

## Trampas de integración

- Bandejas, menús y `NSStatusItem`, incluida su destrucción, en el hilo principal.
- Declarar cada ventana en `capabilities/main.json` para habilitar IPC/eventos.
- `settings_save` sólo acepta claves de `SETTABLE` en `src/runtime/library/store.ts`.
- Un comando de biblioteca nuevo se registra en el controlador Bun y en
  `UI_CONTROLLER_METHODS`; su autorización para recetas se decide en TypeScript.
  Un comando de cáscara o conocimiento se declara en `command.rs`. Documentar
  cada método en `CONTRACT.md`. `apps/tauri/src/generated` sale de Rust:
  regenerar con `ESCRIBA_WRITE_BINDINGS=1 cargo test --lib los_tipos_generados`,
  nunca editar a mano.
- La lista de biblioteca omite segmentos y paquetes completos; el detalle usa
  `recording_detail`. Guardar configuración conserva `bundle` y `program` si el
  cliente no los envía.
- Fallar al leer una carpeta no equivale a una carpeta vacía. El resultado real
  del escaneo decide el aviso de autorización, no la presencia de un bookmark.
- Notion pagina de cien en cien; conservar reintentos limitados a operaciones
  repetibles y el recibo duradero antes de efectos externos.
