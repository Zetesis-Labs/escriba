# Auditoría de decisiones en Escriba Tauri

Puerta 3 del ADR-0004. Cada decisión del `CLAUDE.md` de `feat/personas`
contrastada con el código de Tauri (commit 78a0598), con su evidencia. La hizo
un agente de solo lectura el 2026-10-09; Claude verificó en el código los
hallazgos marcados con «verificado» y revisó en los hilos de Codex qué
decisiones dio Rubén de verdad.

Rutas: `controller.ts`, `worker.ts`, `summary.ts`, `memory.ts` y
`connectors.ts` están en `apps/tauri/src/runtime/`; los `.rs` en
`apps/tauri/src-tauri/src/`; `notion.ts` en `packages/conectores/src/`.

## Qué decidió Rubén y qué decidió Codex

Leído en el hilo de Codex del 2026-10-08 y 09:

| Decisión | Origen |
|---|---|
| Migrar el escritorio a Tauri, primero como experimento y a las 23:13 como migración completa | Rubén |
| «Igualar las funcionalidades» y «sin borrar lo que ya tenemos» | Rubén, 22:41 |
| Swift solo para APIs nativas | Rubén, 22:50 |
| SurrealDB, «nada de guardar en un cutre JSON» | Rubén, 23:15 |
| Todos los conectores son responsabilidad de TypeScript | Rubén, 21:47 |
| Recetas con librerías npm instalables | Rubén, 20:43 |
| Autorizar carpetas sueltas antes que el acceso total al disco | Rubén, 12:45 |
| Orquestar en un ejecutable Deno | Codex, sin comentarlo con Rubén. Rubén, 2026-10-09: **Bun**, con el sandbox de macOS por proceso de receta en lugar de los permisos de Deno |
| esbuild nativo empaquetado y compilar a mano con «Compilar» | Codex |
| Retirar el editor de pastillas también de la app Swift | Codex, contra «sin borrar lo que ya tenemos» |
| Notion real «fuera del alcance» de las pruebas | Codex |

El `CLAUDE.md` de `main` dice «Zod es el único paquete de npm»; la petición
de Rubén de las 20:43 lo sustituye. Hay que actualizarlo al mergear.

## Incumplimientos, de más a menos daño

1. **Personas no existe y se pierden datos** (verificado). El host nativo
   devuelve texto y segmentos y descarta las huellas (`NativeHost.swift:114-121`).
   La importación no copia las tablas `voice` ni `person`. Al reprocesar se
   reutilizan versiones diarizadas sin huellas, al revés de la regla.
2. **La receta se fija al incorporar la nota** (verificado). `store.rs:926`
   graba la por defecto de ese momento y `controller.ts:228` la prefiere. Si
   Rubén cambia la por defecto, las notas ya incorporadas se procesan y publican
   con la anterior. En Swift se resuelve en cada nota.
3. **No se puede configurar un destino sin escribir código y no hay editor de
   plantillas.** El Notion que genera la app sale con la base vacía
   (`project.rs:279`) y falla hasta editar el proyecto a mano.
4. **Notion nunca se ha probado contra el servicio real**, con un SDK y una
   versión de la API nuevos.
5. **Reprocesar una nota importada de Swift la vuelve a transcribir entera**
   (verificado por Claude, no por el agente). Sus criterios se importaron sin la
   huella del audio ni el modelo y con el nombre de motor de Swift
   (`migration.rs:322`), así que nunca coinciden con los de Tauri.
6. **esbuild nativo empaquetado y compilación manual**, en vez de esbuild en
   WebAssembly descargado al elegir la carpeta. Decisión de Codex.
7. **Las decisiones no son funciones puras con test**: viven dentro de closures
   con E/S en `controller.ts` y `jobs.rs`.
8. **El núcleo ya no viaja**: la sonda WASI salió del CI.

Parciales que hacen daño:

- Quitar un destino del proyecto y recompilar deja «Por defecto» fallando en
  Zod (`catalog.rs:77-86`).
- La versión nueva pasa a vigente en `version_save`, antes de `guardar()`; si
  la receta falla después, se queda vigente.
- «Generar» el resumen a mano devuelve el que ya había y usa siempre Apple
  Intelligence, aunque la receta use otro LLM. Swift lo rehace con el LLM y el
  prompt de «Por defecto».
- No hay ledger: lo pendiente sale del estado de la biblioteca más la tabla de
  trabajos.
- Ajustes añade Notificaciones, Importar y Almacenamiento.

## Tabla completa

| Decisión | Evidencia en Tauri | Veredicto |
|---|---|---|
| Producto OSS: configurar sin leer código | `App.tsx:2170-2174`; `project.rs:243-288` | Incumple |
| Verificar contra el servicio real | `apps/tauri/README.md` | Incumple |
| El núcleo viaja a WASI con su sonda en el CI | `ci.yml:70-80` | Incumple |
| Tauri reabierto solo si Rubén lo pide | Hilo de Codex, 22:41 y 23:13 | Cumple |
| Lista de recetas de formulario y código; la elegida al añadir o grabar manda | `lib.rs:286,386`; `store.rs:897` | Cumple |
| La por defecto se resuelve en cada nota | `store.rs:926`; `controller.ts:228` | Incumple |
| `procesar` pasa la grabación a otra receta | `controller.ts:607-615`; `worker.ts:205-217` | Cumple |
| Sin receta por carpeta ni exportar recetas sueltas | `store.rs:1343-1358` | Cumple |
| Runtime detrás de un puerto; el límite no cuenta las esperas | `contracts.ts:24-26`; `worker.test.ts:358,380` | Parcial: Deno, decisión de Codex |
| esbuild en WebAssembly descargado | `tauri.conf.json:35`; `lib.rs:1103` | Incumple |
| Paquetes npm en las recetas | `project.rs:31-43` | Cumple la petición de Rubén de las 20:43 |
| Parámetros con `buildRecipeForm`; se guarda lo cambiado; un valor inválido falla nombrando el campo | `worker.ts:127-149`; `SchemaForm.tsx:66-67` | Cumple |
| «Por defecto» declara el formulario con Zod | `defaultRecipe.ts`; `controller.ts:99-112` | Cumple |
| La receta por defecto vive en `receta.ts` | `worker.ts:224-249` | Parcial: el flujo está reimplementado en `worker.ts` |
| Monaco aparcado | `App.tsx:2990-3012` | Cumple |
| Decisiones en funciones puras con test | `controller.ts:213-695`; `jobs.rs:80-111` | Incumple |
| Plantillas con editor de pastillas y «/» | `notion.ts:241-359` | Incumple |
| Un destino recibe una `Note` | `connectors.ts:25-35` | Cumple |
| Mínimo macOS 26 | `tauri.conf.json:38-39` | Cumple |
| Base de datos | `docs/tauri-persistence.md` | SurrealDB por decisión de Rubén, 23:15 |
| El pipeline no adivina cuántos hablan | `NativeHost.swift:99-104` | Cumple |
| El ledger es la única fuente de verdad | `jobs.rs:80-111` | Parcial |
| Toda grabación escaneada tiene fila | `lib.rs:710-775` | Parcial: vacías e iCloud aparecen al asentarse |
| Descartar no reprocesa | `jobs.rs:52-54, 91-99`; `store.rs:807` | Cumple |
| 0 bytes más de una hora = abandonada | `watcher.rs:359-366`, test `watcher.rs:653-661` | Cumple |
| Un reintento no vuelve a transcribir ni resumir | `controller.ts:409-420, 456-461`; `memory.ts` | Cumple, salvo lo importado de Swift |
| Reprocesar a mano: versión nueva reutilizando la transcripción | `controller.ts:413-461`; `recovery.test.ts:54` | Cumple en notas de Tauri; incumple en importadas |
| `guardar()` fija la versión vigente | `store.rs:1031`; `controller.ts:513-534` | Parcial |
| Modelos en la carpeta propia, nunca los de MacWhisper | `WhisperKitBackend.swift:12-14` | Cumple |
| WhisperKit único motor local | `NativeHost.swift:94-122` | Cumple |
| Personas y huellas que no salen del Mac | `NativeHost.swift:114-121`; `migration.rs` | Incumple |
| Resolutores en plural, sin favorito, locales fijos | `controller.ts:71-84`; `store.rs:1078-1089` | Cumple |
| Quitar un resolutor o conector lo borra de los valores | `store.rs:1150-1156`; `catalog.rs:77-86` | Parcial |
| El prompt vive en la receta | `receta.ts:45-50` | Cumple |
| Sin paquete de la por defecto, las notas esperan | `controller.ts:229-237`; `jobs.rs:20-25` | Cumple |
| Ajustes solo con General y Carpetas | `App.tsx:3321-3669` | Parcial |
| Sin fallback a local | `controller.ts:79-82` | Cumple |
| Fallos globales esperan; 413 y 400 marcan fallida | `remote.rs:49-61`; `jobs.rs:151-181` | Cumple |
| Un resolutor caído solo retiene sus notas | `jobs.rs:112-135` | Cumple, con espera por nota |
| Clave leída en cada llamada; diarizar solo en local | `lib.rs:321-345` | Cumple |
| Token en fichero 0600 por conector | `store.rs:41-50, 624-649` | Cumple; los de Swift no se migran |
| Los tokens nunca llegan al JavaScript | `scripts.rs:127-151`, tests `store.rs:2109` | Cumple |
| Base, columnas, cuerpo e interruptor desde la app | `project.rs:270-280` | Incumple |
| Rastro de publicación por conector | `store.rs:1204-1222` | Cumple |
| Reprocesar regenera la página con el mismo enlace | `connectors.ts:89-94`; `notion.ts:488-551` | Parcial: el recibo conserva la configuración antigua |
| Un fallo de conector no tumba el pipeline; publicar a mano muestra el error | `receta.ts:81-87`; `worker.ts:242-248` | Cumple |
| Token del usuario, no OAuth | `App.tsx:2073` | Cumple |
| Sin ventana de Ajustes | `lib.rs:1171-1176` | Cumple |
| Resumir es un puerto y el motor trocea | `summary.ts:3-78` | Cumple |
| Reducción en cascada con tope | `summary.ts:44-77`; `recovery.test.ts:377` | Cumple |
| Un `Digest` vacío es un fallo | `summary.ts:16-25` | Cumple |
| Resumen encendido en castellano; si falla, se guarda con aviso | `receta.ts:18-22`; `pipeline.test.ts:7` | Cumple |
| El resumen es de la versión | `store.rs:1053-1066` | Cumple |
| Resumir a mano se ancla a la versión leída | `controller.ts:697-749` | Parcial |
| Quitar el resumen republica con columnas vacías | `notion.ts:254-271`; `connectors.test.ts:367` | Cumple |
| Diarizar se pide a mano | `receta.ts:26-30` | Cumple |
| Notion pagina de 100 en 100 | `notion.ts:600-617`; `connectors.test.ts:549` | Cumple |
| 429 con `Retry-After` | `notion.ts:391`; `connectors.test.ts:266` | Cumple |
| Crear página nunca se reintenta tras un corte | `notion.ts:366-388, 529-561` | Cumple |
| Apple: 3500 caracteres por petición y 900 tokens | `AppleSummarizer.swift:21-22, 39` | Cumple |
| Reprocesar guarda la versión antes de resumir | `controller.ts:456-461` | Cumple |

No aplican a Tauri: nada de Combine, el daemon de concurrencia estructurada de
Swift y la sincronización de descartadas entre ledger y biblioteca.
