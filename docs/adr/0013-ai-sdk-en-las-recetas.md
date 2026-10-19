# El AI SDK dentro de las recetas, sin claves

Decidido por Rubén el 2026-10-19. Depende del ADR-0012 (el AI SDK en el
controlador) y del ADR-0011 (las recetas aisladas, sin red, disco ni claves).

## Contexto

Las recetas piden inferencia a Escriba con `escriba.preguntar`. Lo demás que
ofrece el AI SDK no les llega: herramientas, agentes de varios pasos, salida
estructurada con sus opciones, `streamText` o elegir modelo por llamada.

Darles el SDK con sus proveedores les daría red y claves. Pero el SDK separa dos
capas:

- **Las funciones** (`generateText`, `streamText`, `Output`, `tool`): lógica sin
  red.
- **El modelo:** un objeto que cumple la interfaz `LanguageModelV4` y hace la
  llamada.

Solo la segunda capa necesita red y clave.

Una prueba del 2026-10-19 contra Ollama lo confirmó. La receta se empaquetó como
lo hace Escriba, se cargó sin `fetch` ni `WebSocket`, y entre receta y
controlador solo viajó JSON. Funcionaron `generateText`, `Output.object` con
Zod, una herramienta ejecutada dentro de la receta en dos pasos y `streamText`.
Con `ai` dentro, el paquete ocupa 618 KiB y carga en 47 ms (73 ms de CPU).

## Decisión

1. **La receta usa su propio `ai`**, instalado con npm en su proyecto (versión
   7, la que habla `LanguageModelV4`), y se empaqueta dentro como cualquier
   dependencia. Escriba no lo añade a las dependencias que gestiona.
2. **`escriba.modelo(claveONombre)` devuelve un modelo intermediario** que
   cumple `LanguageModelV4` sin depender del SDK. Sus `doGenerate` y `doStream`
   piden la llamada al controlador por el canal de la receta.
   - El worker registra a Escriba como proveedor por defecto del SDK
     (`AI_SDK_DEFAULT_PROVIDER`), así que `model: "claude"` es lo mismo que
     `escriba.modelo("claude")`. Un nombre nunca acaba en el gateway de Vercel.
3. **Solo resolutores LLM remotos y encendidos**, elegidos por clave o nombre
   como en `preguntar`. Apple Intelligence va por el host nativo, fuera del
   SDK, y responde con un error claro.
4. **El controlador es la frontera, no el worker.** Una receta puede llamar al
   canal sin pasar por el intermediario, así que el controlador valida cada
   llamada:
   - acepta solo las opciones `prompt`, `maxOutputTokens`, `temperature`,
     `topP`, `topK`, `presencePenalty`, `frequencyPenalty`, `stopSequences`,
     `seed`, `responseFormat`, `reasoning`, `tools` y `toolChoice`. Rechaza el
     resto, entre ellas `headers`, `providerOptions` e `includeRawChunks`;
   - rechaza las herramientas que ejecuta el propio proveedor
     (`type: "provider"`, como la búsqueda web), porque harían salir al
     proveedor a internet en nombre de la receta;
   - en el prompt acepta solo partes de texto, razonamiento, llamada a
     herramienta y resultado de herramienta. Mandar archivos (imágenes, audio)
     queda para otra decisión.
5. **La receta recibe solo** `content`, `finishReason`, `usage` y `warnings`.
   Nunca `request`, `response` ni `providerMetadata`. Los errores llegan como en
   la fase 1 del ADR-0012: un mensaje con la clave tapada y su código
   (`backend_unavailable` o `failed`), sin la URL ni el cuerpo del servidor. La
   prueba mostró que un error sin limpiar puede llevar la clave que el servidor
   repite.
6. **Lo ya hecho no se vuelve a pagar.** Cada llamada se recuerda con su huella,
   igual que `preguntar`: `{kind: "model", resolver, method, options}`, por
   grabación y con las mismas reglas de reprocesar.
7. **El tope de llamadas a LLM por nota: 50** (`requisito-recetas.md`), que
   hasta ahora no existía. Una receta con herramientas puede encadenar muchas
   llamadas. Cuenta `preguntar` y `modelo` de cada ejecución. Al llegar al
   tope, la siguiente falla y la nota lo muestra.
8. **`doStream` entrega el resultado de una vez.** El controlador recoge las
   partes y el intermediario las reproduce como un `ReadableStream`. Un
   streaming real pediría varias tramas por llamada en el canal, y en recetas
   que corren en segundo plano casi no aporta.
9. **`preguntar` sigue siendo la vía tolerante.** Con `escriba.modelo`, la
   receta tiene el comportamiento del SDK tal cual. Por ejemplo, un JSON entre
   vallas con `Output.object` falla. Lo dice la documentación de recetas.

## Alternativas

- **Que Escriba aporte `ai` a los proyectos, como Zod.** Habría que copiar al
  `vendor` y a cada proyecto `ai` con sus dependencias: el gateway, `@vercel/oidc`,
  `undici` y siete paquetes más. A cambio, todas las recetas compartirían
  versión. Se descarta mientras las recetas puedan instalar la suya.
- **Exponer funciones sueltas en `escriba.*`** (opciones de `preguntar`,
  embeddings…). Habría que copiar el SDK a mano, función a función.
- **Dar a las recetas los proveedores del SDK con su clave.** Descartada: rompe
  el aislamiento del ADR-0011.

## Consecuencias

- **Versión de `ai`:** una receta que use otra versión mayor, con otra interfaz
  de modelo, recibe el error del SDK sobre la versión del modelo. Cuando
  Escriba cambie de interfaz, cambiará `escriba.modelo` y lo anunciará.
- **Ajustes propios de cada proveedor:** quedan fuera hasta decidir cuáles son
  seguros.
- **Embeddings y reranking:** tendrían su propio intermediario, si se piden.
- **`@vercel/oidc`:** `ai` lo arrastra en el paquete de la receta, y pide `fs`,
  `os` y `path` al cargar. El aislamiento del sistema sigue impidiendo leer
  fuera de lo permitido, y con el proveedor por defecto de Escriba el gateway
  nunca se usa.
