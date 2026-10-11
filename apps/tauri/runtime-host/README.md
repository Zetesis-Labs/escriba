# Host TypeScript aislado

El WebView solo importa `src/runtime/index.ts`, cliente IPC. Rust conserva la
cola duradera y supervisa este proceso. El controlador TypeScript conserva las
reglas de recetas y conectores; no recibe credenciales ni permisos de E/S.

## Compilación

```sh
node apps/tauri/runtime-host/build.mjs \
  apps/tauri/src-tauri/binaries/escriba-runtime-aarch64-apple-darwin \
  aarch64-apple-darwin
```

Requiere dependencias npm instaladas y la versión de Bun fijada en
`bun-version`. `buildRuntime({output,bun,target})` incluye el SDK, Zod, el
controlador y los programas de workers/conectores en un ejecutable autónomo.
Desactiva la carga de `.env` y `bunfig.toml` y la instalación automática de
imports. El binario se firma antes de probarlo y se vuelve a firmar al
empaquetar la app. El usuario final no necesita instalar Bun, Node ni npm.

La construcción de la app usa esbuild como dependencia de desarrollo. El
ejecutable distribuido construye los proyectos de recetas con `Bun.build` y
produce `dist/escriba.json` y los paquetes JavaScript. No se distribuye otro
ejecutable de esbuild. El cargador solo lee `dist/`: las fuentes y
`node_modules` son necesarios para construirlo, no para ejecutarlo.

El modo `--project-build` tiene un sandbox de desarrollo separado: puede leer
el proyecto y las dependencias incluidas, y escribir dentro del proyecto.
`project_tool` expone instalación sin scripts de ciclo de vida, comprobación
con TypeScript 7.0.2 nativo en Go y pruebas con Bun. Solo la instalación permite
red. Esos procesos no reciben capacidades de notas ni credenciales. El editor
CodeMirror llama a estas operaciones; no ejecuta código en la WebView.
El [contrato del proyecto](../../../docs/proyecto-recetas-tauri.md) describe
el artefacto, las herramientas y sus límites.

## Protocolo v1

JSONL UTF-8 por stdin/stdout. El host anuncia
`{type:"ready",protocolVersion:1}`. IDs de petición: cadena o entero seguro.

Cada trama tiene un máximo de 32 MiB en bytes UTF-8, tanto en Rust como en
TypeScript. Si una respuesta de capacidad supera ese tamaño, Rust envía un
rechazo legible y conserva la sesión para el siguiente trabajo. Los errores al
leer el protocolo conservan su causa en el error del trabajo.

- Rust → host: `run {id,operation,args}`, `cancel {id}`.
- Host → Rust: `result {id,value}`, `error {id,message,code}`.
- Host → Rust: `call {id,method,params,taskId}`; respuestas `resolve {id,value}`
  o `reject {id,message,code}`. `taskId` conserva el ID de ejecución incluso al
  responder capacidades de una receta.
- Host → Rust: `event {event:"jobs",value:JobState[]}`.
- Host → Rust: `worker_create {id,taskId}`, `worker_send {id,value}`,
  `worker_terminate {id}`.
- Rust → host: `worker_message {id,value}`, `worker_error {id,message}`.

Rust crea cada worker ejecutando el mismo binario con `--worker`, entorno limpio
y tuberías exclusivas. Este modo consume `start/resolve/reject` y produce
`call/result/error`, el protocolo del adaptador Worker existente. Rust reenvía
sus mensajes al controlador, que valida cada operación en el contexto de la
nota y cuenta autorizadas. Máximo ocho workers simultáneos. Rust debe terminar
sus procesos al cerrar/reiniciar el host y aplicar el límite total del trabajo.
El tiempo de espera de capacidades no consume el presupuesto CPU del adaptador.

Los códigos `backend_unavailable`, `recipe_unavailable` y `runtime_unavailable`
permiten reintentar; `microphone_denied` y `failed` conservan un fallo terminal.
Un mensaje de error sin código conocido se trata como `failed`, aunque su texto
contenga un marcador antiguo. Los rechazos de capacidades y de workers conservan
el código hasta la cola duradera.

Los proyectos pueden aportar proveedores con formularios declarativos. El
controlador ejecuta `connectorEditor` en un worker: describir y validar no
concede capacidades; una acción explícita accede a la cuenta que la UI indique.
No se ejecuta código del proveedor en la WebView ni se repiten esas acciones al
recuperar trabajos. Los resultados se validan contra `ConnectorView` antes de
renderizarlos.

El fetch de `escriba.cuenta(id)` usa `account.http`. Cada petición relee la
autorización y Rust vuelve a contrastar `expectedGrant`, origen y cabeceras antes
de inyectar el secreto. Una escritura de SDK confirma antes
`accountEffectPending` en la grabación; se conserva incluso al terminar para
cubrir un cierre previo al acuse del job. Una ejecución manual nueva retira la
marca; un trabajo automático, recuperado o reintentado se bloquea. Los SDK pueden
tener sus propios reintentos: la receta debe desactivarlos o asegurar la
idempotencia cuando modifique recursos.

El controlador consulta `runtime_context({recordingId?})`: catálogos, ajustes de
procesamiento y únicamente la grabación solicitada con sus versiones y recibos.
Sin `recordingId` obtiene solo configuración. No recibe registros, otras notas,
carpetas vigiladas ni rutas de audio. La consulta `snapshot` completa pertenece
a la interfaz y no es una capacidad del controlador. El tamaño total de la
biblioteca no determina el tamaño de cada trabajo.
El origen de la nota y la carpeta de una cuenta se representan con identificadores
opacos. La huella de la carpeta permite invalidar una operación si cambia su
destino mientras se ejecuta, sin entregar la ruta al controlador.

`processRecording` admite `options.values` para los parámetros de una sola
ejecución. Si se omite usa los guardados en la receta; si se envía, sustituye
esos valores, incluido `{}` para usar los de serie. No guarda el cambio y solo
lo aplica a la receta elegida: las recetas llamadas con `procesar` usan sus
propios valores. `getRecipeSchema` devuelve `null` cuando una receta de código
no exporta `buildRecipeForm`.

## Aislamiento

Rust inicia el controlador y cada worker mediante `/usr/bin/sandbox-exec`, con
el perfil incluido en `sandbox.sb`, entorno vacío y directorio `/`. El perfil
parte de `deny default`; permite leer el propio ejecutable y las bibliotecas de
macOS y sus datos ICU de `/usr/share/icu`, pero deniega archivos del usuario,
escritura, red y nuevos procesos.
Las APIs de Bun/Node siguen existiendo: la restricción la impone macOS.

Cada receta tiene sus propias tuberías. Escribir una trama falsa en stdout no
permite acceder al canal privilegiado del controlador: este valida los mensajes
del worker y Rust valida las capacidades y la vigencia del trabajo. Los errores
de arranque conservan hasta 2 KiB de diagnóstico; stderr de las recetas se drena
sin publicarlo ni guardarlo.

El perfil se ha probado en macOS 26 con Bun 1.4.2. `sandbox-exec` está obsoleto en
los manuales de Apple y requiere repetir las pruebas al cambiar de macOS/Bun.
Un fallo del sandbox impide el arranque, sin ejecución alternativa desprotegida.
Fuentes y pruebas de compatibilidad en
[la investigación de Bun](../../../docs/investigacion-bun-sandbox.md).

## Evidencia

`tests/runtime/sidecar.test.ts` compila y lanza el ejecutable real con un host
falso por tuberías: guarda antes de resumir, reinicia sin repetir transcripción,
cancela una receta CPU, comprueba denegación de archivos/red y rechaza una
capacidad falsificada mediante stdout del proceso de receta. Usa solo fixtures,
archivos temporales y un servidor local sintético. Comprueba también que
`node:child_process` y `Bun.spawnSync` no pueden relanzar el propio ejecutable.

Las pruebas Rust de `scripts` ejercitan el ejecutable compilado con una
biblioteca sintética mayor de 32 MiB y comprueban que puede procesar una nota.
Otra prueba compila un proyecto con una dependencia local de `node_modules`
y ejecuta su receta hasta guardar una versión. La prueba de memoria usa el
supervisor Rust real; el arnés TypeScript no simula ese supervisor.
`Store::runtime_context` se valida con SurrealKV, conservando versiones y recibos
de la nota elegida y excluyendo datos ajenos.

## Paridad con la biblioteca anterior

La revisión de `RecipeSession` y `NoteMemory` detectó tres pérdidas de estado que
se han corregido en el controlador: preguntas repetidas al reanudar, inferencias
de resumen repetidas después de completarse y ausencia de trazas de pruebas.
`memory_recall/memory_keep` guardan respuestas por grabación, versión y SHA-256
canónico de la petición, modelo, URL e instrucciones/esquema. Se valida la
respuesta antes de guardarla. Los bloques y reducciones de resumen se recuerdan
antes de actualizar el resumen de la versión. Una nueva versión manual tiene
su propia memoria. Las pruebas no escriben versiones ni memoria, y conservan su
resultado en `trace_save`.

El Registro muestra trabajos duraderos, reintentos y trazas con duración de cada
paso. La captura se recupera consultando el proceso grabador; el WebView no
reconstruye ese estado ni vuelve a encolar grabaciones al abrirse. La migración
se ofrece explícitamente en Ajustes y conserva la biblioteca de origen. El
borrado permanente de notas exige confirmación y no retira sus publicaciones
externas.

Diferencia deliberada: un resumen antiguo sin identidad de petición no se
reutiliza como respuesta de otro modelo/prompt. Puede recalcularse una vez para
crear la memoria compatible. Los permisos, el almacenamiento duradero y las
notificaciones se resuelven en Rust; Whisper/diarización, Foundation Models y
AVFoundation siguen en el proceso nativo.

## Límites verificados

Rust mide la memoria residente de cada worker cada 50 ms mediante
`proc_pidinfo` y termina el proceso si observa más de 512 MiB. Comprueba su
identidad para evitar actuar sobre un PID reutilizado; si no puede vigilarlo,
la ejecución falla. La prueba sintética retiene memoria hasta superar el límite
y verifica que el controlador sigue respondiendo.

Es un límite operativo: puede haber exceso entre muestras. No equivale al
antiguo límite de old-space de V8 ni a una cuota estricta del heap. Las opciones
de heap de Bun 1.4.2 no impusieron un tope en las pruebas; no se usan como
protección.

Recetas y conectores tienen diez segundos acumulados de ejecución entre
capacidades, igual que el límite predeterminado de JavaScriptCore anterior.
El adaptador resta el tiempo transcurrido antes de cada RPC y lo reanuda al
terminar las capacidades pendientes. La inferencia lenta no consume ese
presupuesto; dividir el trabajo en varios RPC tampoco lo reinicia. El
supervisor aplica además el límite total y termina todos los procesos hijos.

## Comprobación de tipos del host

```sh
cd apps/tauri
npm run typecheck:runtime
```

Comprueba `runtime-host/main.ts` y sus imports originales con el TypeScript y
los tipos Node ya instalados en el proyecto. La configuración temporal hereda
los aliases de la app. Es independiente del empaquetado de Bun; no instala
paquetes ni necesita red.
