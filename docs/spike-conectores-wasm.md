# Spike: conectores como plugins WebAssembly cargados en caliente

Estado: **medido el 2026-10-06** en la rama `feat/conectores-wasm`. Responde a
dos preguntas de Rubén: si es viable que los conectores sean plugins `.wasm`
que el usuario importa sin reiniciar la app, y qué hándicap se paga con cada
forma de ejecutarlos, por mucho que se afine.

## Lo que hay en la rama

- **Contrato** (`EscribaPluginKit`, portable): manifiesto, nota serializable,
  petición y respuesta en JSON, y un **formulario declarativo** que el plugin
  describe y la app pinta con sus controles nativos (secciones, texto,
  secreto, carpeta, desplegable con opciones del plugin, plantillas con «/» y
  enlaces, pestañas de N documentos con añadir y quitar, filas clave-valor con
  `type` protegido, botones de acción, vista previa). El editor del plugin no
  pierde nada frente al nativo: lo mismo que hoy hacen `NotionEditor` y
  `OKFEditor`, descrito por el plugin.
- **Plugins** `escriba-plugin-okf` y `escriba-plugin-notion`: los conectores
  de siempre con sus dos puertos (`OKFFolder`, `NotionTransport`) implementados
  sobre tres imports del host (`escriba.call`, `take`, `respond`). Son
  **reactores** WASI: se instancian una vez y atienden llamadas por
  `escriba_handle`; el trabajo asíncrono dentro de la exportación se drena con
  `swift_task_donateThreadToGlobalExecutorUntil`.
- **Host** (`EscribaPlugins`): hoy sobre WasmKit. Sesión persistente por
  módulo, HTTPS solo a los dominios del manifiesto, claves sustituidas en las
  cabeceras sin que el plugin las vea, ficheros solo dentro de la carpeta
  elegida, zonas horarias pre-abiertas en solo lectura, salida del plugin al
  log, y si el plugin se rompe la siguiente llamada arranca una instancia
  nueva.
- **App**: sección Conectores con «Importar plugin…» (`.wasm` → `describe` →
  copia a `~/Library/Application Support/escriba/plugins`), conector de clase
  `.plugin` con configuración JSON y secretos aparte, publicación y
  despublicación por el sink del plugin.
- `scripts/build-plugins.sh` compila los plugins; `scripts/run-plugin.mjs` los
  ejecuta bajo Node con un host de ficheros para depurar fuera de la app.

Ambos plugins funcionan de punta a punta: OKF escribe el bundle completo
(`index.md`, `log.md`, `notas/`, `transcripciones/`); Notion se describe, da
su formulario y pide el token (la publicación real necesita un token y no se
ha probado).

## Medidas

Mismo módulo (`okf.wasm`, 59 MB, con Foundation), mismas peticiones, mismo Mac
(M-series). Tiempos por llamada con la instancia viva.

| | WasmKit 0.4.1 (intérprete, Swift puro) | JavaScriptCore (framework del sistema) | wasmtime 49 (JIT, API C) | Node 22 (referencia) |
|---|---|---|---|---|
| Cargar o compilar el módulo | 0,14 s (parsear) | 126 ms | 1,56 s; **23 ms** precompilado (`.cwasm`, 111 MB) | — |
| Instanciar e inicializar | 0,16 s | 12 ms | 5 ms | — |
| `describe` | 0,67–0,75 s (primera llamada: arranque de Foundation interpretado) | 5,8 ms; 1,4 ms caliente | 1,1 ms | 8 ms |
| `form` (sin vista previa) | 0,65–0,9 s | 38–51 ms | 1–2 ms | — |
| `form` con vista previa dentro | 2,6–4,9 s | — | — | 43 ms |
| `preview` | 1,9–3,3 s | ~100 ms | 3–6 ms | — |
| `publish` | 2,3–3,6 s | 90 ms | 7 ms | 44 ms |
| Tras 30 llamadas | igual | igual (no sube de nivel) | igual | — |
| WASI | sí (preview 1) | no: shim propio en JS (~120 líneas, con lectura de `zoneinfo`) | sí, completo | sí |
| Tiempo límite a un plugin | fuel | no | fuel y época | no |
| Linux (pod) | sí | no | sí (el mismo runtime que Spin en Kubernetes) | — |
| Dependencias | ninguna | ninguna (macOS) | `libwasmtime.dylib`, 24 MB, en C, firmada dentro de la app | — |

Otras medidas:

- Módulo Swift sin Foundation: 7,8 MB con nombres, 0,5 MB sin ellos; con
  Foundation, 59 MB, de los que ~7 MB son nombres (`--strip-all` → 51,8 MB) y
  ~35 MB son ICU, que el enlazador no puede recortar. `FoundationEssentials`
  sola no ayuda: arrastra ICU igual (57,6 MB).
- El 70 % del `form` bajo WasmKit era la vista previa (fechas con ICU);
  separarla en un comando `preview` deja el formulario en 0,65 s bajo el
  intérprete.
- Con `TZ=UTC`, Foundation en WASI no toca ficheros; con cualquier otra zona
  lee `/usr/share/zoneinfo` y, si no está pre-abierto, cae en `unreachable`
  sin mensaje.

## Hándicaps que no se van por mucho que nos esforcemos

1. **Tamaño con Foundation: 50–60 MB por plugin.** Es ICU. Solo se baja
   quitando Foundation del camino de los plugins (ADR 0001,
   `EscribaFoundation`): fechas gregorianas y JSON propios. Entonces un plugin
   pesa menos de 1 MB.
2. **Un intérprete en Swift puro va a segundos.** WasmKit ejecuta Foundation
   60 veces más lento que un JIT. Vale para publicar en segundo plano; no
   para una pantalla que responde al teclear. Sin Foundation bajaría, pero el
   factor del intérprete sigue.
3. **Velocidad nativa cuesta una dependencia en C.** wasmtime da 1–7 ms por
   llamada y arranque de 23 ms precompilado, con WASI y tiempos límite de
   serie, en Mac y en Linux. El precio: 24 MB de dylib en C firmada en la
   app, y un envoltorio `systemLibrary`. Rompe «solo Swift» en la capa del
   runtime.
4. **JavaScriptCore es el término medio sin dependencias**, solo en macOS:
   40 ms el formulario, 100 ms publicar, shim WASI a mano y, con el runtime
   endurecido, el permiso `allow-jit`. No sube de nivel de JIT con el uso que
   le damos.
5. **El reactor usa una función interna del runtime de Swift**
   (`swift_task_donateThreadToGlobalExecutorUntil`) para ejecutar código
   asíncrono dentro de una exportación síncrona. Sin ella, cada llamada
   reinstanciaría el módulo y pagaría el arranque de Foundation.
6. **Dos descripciones de la misma pantalla.** El formulario declarativo del
   plugin y el editor nativo de SwiftUI describen lo mismo. Es inherente a que
   la pantalla no viaje en el plugin; se mitiga si los conectores de serie
   pasan a ser plugins y el editor nativo desaparece.

## Recomendación

- **Runtime del producto: wasmtime**, en Mac y en el pod de Linux (el mismo
  que ya corre Spin en el spike de Kubernetes), con el módulo precompilado en
  caché. WasmKit se queda para los tests del host (módulos WAT, sin
  dependencias) y como respaldo si alguna plataforma no tiene wasmtime.
- **Tamaño: `EscribaFoundation`** (ADR 0001), empezando por el plugin OKF y
  midiendo tamaño y latencia en cada paso. Es trabajo aparte, en rama propia
  desde `main`.
- **Hooks** (`docs/requisito-hooks-wasm.md`): mismo runtime y mismo contrato;
  el tiempo límite sale gratis con la época de wasmtime.

## Reproducir

```bash
./scripts/build-plugins.sh                      # .build/plugins/{okf,notion}.wasm
ESCRIBA_PLUGIN_OKF=$PWD/.build/plugins/okf.wasm ESCRIBA_PLUGIN_NOTION=$PWD/.build/plugins/notion.wasm \
  swift test --filter PluginsRealesTests        # WasmKit, con tiempos
echo '{"command":"form","config":{"folder":"/tmp/b"},"state":{},"timeZone":"UTC"}' \
  | node scripts/run-plugin.mjs .build/plugins/okf.wasm /tmp/b   # Node
```

Las sondas de wasmtime (`wtprobe`, API C 49.0.2) y de JavaScriptCore
(`jscprobe`, shim WASI en JS) son paquetes desechables de la sesión del
2026-10-06; el código de las dos está resumido en este documento y su
estructura es la del `PluginModule` del repo con otro runtime debajo.
