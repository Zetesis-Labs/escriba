# Exploración: conectores como plugins WebAssembly

Estado: **archivada el 2026-10-06** por decisión de Rubén. El concepto
funciona, pero terminarlo no merece la pena ahora. El código, las medidas
completas, las sondas y el plan para retomarlo están en el PR en borrador
[#3](https://github.com/Zetesis-Labs/escriba/pull/3) (rama
`feat/conectores-wasm`), que no se mergea.

## La pregunta

¿Pueden los conectores ser plugins `.wasm` que el usuario importa en caliente,
como un `.jar` en una app de Java, sin que el editor del conector pierda nada
frente al nativo? ¿Y qué hándicap se paga con cada forma de ejecutarlos, por
mucho que se afine?

## Lo que se construyó

- Un **contrato JSON** entre la app y el plugin: manifiesto (dominios y
  secretos que pide), nota serializable, comandos `describe`, `form`,
  `preview`, `action`, `publish` y `unpublish`.
- Un **formulario declarativo**: el plugin describe la pantalla y la app la
  pinta con sus controles nativos. Cubre todo lo que hacen `NotionEditor` y
  `OKFEditor`: secciones, secretos, carpeta, desplegables con opciones del
  plugin, plantillas con «/» y enlaces, pestañas de N documentos, filas
  clave-valor con `type` protegido, botones de acción y vista previa.
- Los conectores **OKF y Notion recompilados como plugins** en Swift sobre
  tres imports del host. OKF funcionó de punta a punta; Notion se describe,
  pinta su formulario y pide el token, sin probar la publicación real.
- Un **host sandbox**: HTTPS solo a los dominios del manifiesto, claves
  sustituidas por el host en las cabeceras sin que el plugin las vea, ficheros
  confinados a la carpeta elegida.
- **«Importar plugin…»** en la sección Conectores de la app.

## Medidas

Mismo plugin OKF (59 MB, con Foundation), mismas peticiones, mismo Mac.

| | WasmKit 0.4.1 (intérprete) | JavaScriptCore | wasmtime 49 (JIT) |
|---|---|---|---|
| Compilar el módulo | 0,14 s | 126 ms | 1,56 s; 23 ms precompilado |
| `form` | 0,65–0,9 s | 38–51 ms | 1–2 ms |
| `publish` | 2,3–3,6 s | 90 ms | 7 ms |
| Instancia nueva por llamada | — | — | 5–11 ms |
| Linux | sí | no | sí |
| Dependencia | ninguna | ninguna, solo macOS | dylib de 24 MB en C |

| Plugin | Tamaño |
|---|---|
| Con Foundation | 59 MB |
| Solo `FoundationEssentials` | 57,6 MB |
| Sin Foundation | 0,5 MB |

## Conclusiones

1. **Es viable.** El formulario declarativo no pierde capacidades frente al
   editor nativo y la importación en caliente funciona.
2. **El tamaño es Foundation.** ICU son unos 35 MB que el enlazador no
   recorta, y `FoundationEssentials` lo arrastra igual. Solo baja con una
   Foundation mínima propia (`EscribaFoundation`, ADR 0001 en el PR).
3. **La velocidad es el runtime.** Un intérprete en Swift puro ejecuta
   Foundation unas 60 veces más lento que un JIT. WasmKit no sirve para una
   pantalla que responde al teclear. wasmtime da milisegundos.
4. **Con wasmtime los plugins pueden ser comandos normales.** Instanciar por
   llamada cuesta 5–11 ms, así que no hacen falta reactores ni la función
   interna del runtime de Swift que exigían.
5. **Hándicaps que no se van:**
   - Una dependencia en C firmada dentro de la app y una caché precompilada
     por plugin ligada a la versión de wasmtime.
   - Compilar un plugin en Swift tarda un minuto y exige el toolchain de
     swift.org. Para plugins generados por un agente, Swift no es el lenguaje
     adecuado.
   - La pantalla del conector se describe dos veces mientras convivan el
     editor nativo y el plugin.
6. **Trampas para quien lo retome:**
   - Foundation en WASI con `TZ` distinto de UTC lee `/usr/share/zoneinfo` y
     cae en `unreachable` sin mensaje si el host no lo pre-abre.
   - En WasmKit, `WASIBridgeToHost.close()` es obligatorio antes de soltar el
     puente, y `Engine` y `Store` tienen que vivir tanto como la `Instance`.

## Por qué se archiva

Terminarlo son unas dos semanas: wasmtime en la app, `EscribaFoundation`,
migrar los conectores de serie a plugins y los hooks. Es un ecosistema para
dos conectores que ya vienen de serie.

## Si se retoma

1. Partir del PR #3 rebasado sobre `main`.
2. Seguir `docs/roadmap-extensiones-wasm.md` de la rama: wasmtime como
   runtime, plugins como comandos, conectores de serie como plugins y hooks.
3. Dejar `EscribaFoundation` para el final. Sin ella todo funciona, solo que
   cada plugin pesa 59 MB y su caché precompilada 111 MB.

Los hooks del usuario (`docs/requisito-hooks-wasm.md`) usarían el mismo
runtime y el mismo contrato, así que estas medidas también les aplican.
