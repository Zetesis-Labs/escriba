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

Requiere dependencias npm ya instaladas y Deno en el entorno de desarrollo.
`buildRuntime({output,deno,target})` también se exporta para el preparador de la
app. Esbuild incluye el SDK, Zod, el controlador, el adaptador y el programa de
conectores. Deno compila un único ejecutable con permisos read/write/net/env/run/
ffi/sys/import denegados, sin configuración, npm ni módulos remotos. La primera
compilación puede descargar `denort`; la aplicación resultante no necesita Deno,
Node, npm ni descargas de código.

## Protocolo v1

JSONL UTF-8 por stdin/stdout. El host anuncia
`{type:"ready",protocolVersion:1}`. IDs de petición: cadena o entero seguro.

- Rust → host: `run {id,operation,args}`, `cancel {id}`.
- Host → Rust: `result {id,value}`, `error {id,message}`.
- Host → Rust: `call {id,method,params,taskId}`; respuestas `resolve {id,value}`
  o `reject {id,message}`. `taskId` conserva el ID de ejecución incluso al
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

## Investigación y decisión

Los permisos de Deno se incorporan al binario durante `compile`; no se conceden
permisos en producción. [Documentación oficial de compilación](https://docs.deno.com/runtime/reference/cli/compile/).

Deno permite reducir permisos de Web Workers, pero esto no separa sus canales
estándar del proceso. [API oficial de Workers](https://docs.deno.com/examples/web_workers/).
La prueba local con Deno **2.6.9** y todos los permisos denegados confirmó que un
Worker puede usar `Deno.stdin/stdout` y `import('node:process').stdout`. Ocultar
el objeto global no elimina esa segunda vía. Por ello las recetas usan procesos
separados: nunca comparten el canal de capacidades del controlador. La misma
prueba comprobó que Workers `blob:` no cargaban en el binario 2.6.9; no dependemos
de ese mecanismo.

Los permisos niegan acceso a archivos, red, variables, subprocesos y bibliotecas
nativas. [Modelo de seguridad oficial](https://docs.deno.com/runtime/fundamentals/security/).
El aislamiento de procesos añade separación de canales; los límites de memoria
y la duración total corresponden al supervisor Rust.

## Evidencia

`tests/runtime/sidecar.test.ts` compila y lanza el ejecutable real con un host
falso por tuberías: guarda antes de resumir, reinicia sin repetir transcripción,
cancela una receta CPU, comprueba denegación de archivos/red y rechaza una
capacidad falsificada mediante stdout del proceso de receta. Usa solo fixtures,
archivos temporales y ningún servicio real.

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

El compilador incorpora `--v8-flags=--max-old-space-size=512`, opción reconocida
por la ayuda de Deno 2.6.9 y la
[referencia oficial de compile](https://docs.deno.com/runtime/reference/cli/compile/).
Una prueba con una receta que retiene arrays hasta agotar el heap confirma que
termina solo el proceso de receta y que el controlador sigue respondiendo.
El límite de old-space no equivale a un límite de RSS: buffers externos y el
propio runtime pueden ocupar memoria adicional.

Recetas y conectores tienen diez segundos acumulados de ejecución entre
capacidades, igual que el límite predeterminado de JavaScriptCore anterior.
El adaptador resta el tiempo transcurrido antes de cada RPC y lo reanuda al
terminar las capacidades pendientes. La inferencia lenta no consume ese
presupuesto; dividir el trabajo en varios RPC tampoco lo reinicia. El
supervisor aplica además el límite total y termina todos los procesos hijos.

## Revisión de entrega

Revisado el trabajo frente a `b106d0c4bdd3730160710247729264b0aab3bcf7`, `CLAUDE.md`,
`RecipeSession`, `NoteMemory` y las instrucciones de migración autorizadas.

- Estándares: sin `as any`, sin nuevos permisos o servicios implícitos; UI,
  controlador, transporte y almacenamiento mantienen interfaces independientes.
- Especificación: corregidos límites demasiado amplios, memoria compatible y
  liberación de RPC pendientes al cancelar. Los waits de capacidades y el
  presupuesto activo acumulado tienen pruebas públicas.
- Fallos silenciosos: los diálogos de importación ahora usan la misma ruta de
  errores visible; fallar al guardar la traza conserva el error original; un
  fallo de cancelación no envenena permanentemente la cola. Los catches vacíos
  de cola liberan el turno después de entregar el error al llamador; el catch de
  logs del worker aplaza la propagación hasta `Promise.all(logs)`.
- Pruebas críticas: permisos y falsificación de canal, recibos y recuperación,
  reuso compatible y validación antes de cachear, cancelación sin respuesta,
  agotamiento de heap y continuidad del controlador. La presentación visual
  y las notificaciones nativas corresponden a la comprobación de app integrada.

## Comprobación de tipos del host

```sh
cd apps/tauri
npm run typecheck:runtime
```

Este gate comprueba `runtime-host/main.ts` y sus imports TypeScript originales,
no el JavaScript de esbuild. `typecheck.mjs` obtiene las declaraciones oficiales
mediante `deno types`, las guarda temporalmente bajo `.build/typecheck` y ejecuta
el TypeScript instalado por el proyecto con una configuración separada. Hereda
los aliases existentes y los tipos Node instalados para `AsyncLocalStorage`.
No agrega dependencias, no instala paquetes y no necesita acceso a la red.
Las declaraciones corresponden al mismo ejecutable Deno usado al compilar.

Se usa este gate separado porque `deno check` 2.6.9 en modo npm manual no resuelve
`npm:@types/node` desde esta configuración anidada aunque los tipos ya estén
instalados en `apps/tauri/node_modules`. `deno compile --no-check` sigue siendo
solo el empaquetador: CI debe ejecutar este gate antes de compilar/publicar.
