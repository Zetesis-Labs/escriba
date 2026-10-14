# El AI SDK de Vercel para los resolutores remotos

Propuesto el 2026-10-14; **pendiente de decisión de Rubén**. Se haría después
de L6 y L7 de Linux. Depende del ADR-0011: sin él no es posible.

## Contexto

Los resolutores remotos de STT y LLM hablan una API compatible con OpenAI desde
`apps/tauri/src/runtime/remote.ts`, unas 190 líneas escritas a mano:
`chat/completions` con `response_format: json_schema` para `ask` y `summarize`,
`audio/transcriptions` para transcribir, `models` para listar y una prueba con
audio de silencio. Las llaman `domain.ts` (transcribir, preguntar, resumir) y
`commands.ts` (listar modelos y probar un resolutor).

Mientras las credenciales y el HTTP con secreto vivían en Rust (ADR-0003), una
biblioteca de TypeScript no podía tener la clave. Desde el ADR-0011, el
controlador Bun guarda las credenciales, las inyecta en su transporte y hace
las llamadas. Una biblioteca de cliente de modelos puede vivir ahí.

Lo que hoy falla o no existe:

- Si un modelo local (Ollama, LM Studio) ignora `response_format`, resumir
  falla con «El resolutor no respetó el esquema JSON». No hay reintento ni modo
  alternativo.
- Solo hay proveedores compatibles con OpenAI. Anthropic, Gemini o Mistral se
  usan solo si ofrecen esa compatibilidad, y con sus límites.
- No hay streaming ni llamadas a herramientas. Hoy ninguna receta los pide.

## Decisión propuesta

1. **El AI SDK (`ai` y sus proveedores `@ai-sdk/*`) sustituye a `remote.ts`
   dentro del controlador**, y solo ahí. Las recetas siguen pidiendo `ask` y
   `summarize` a Escriba; no reciben claves, red ni el SDK (ADR-0011,
   decisión 3).
2. **El transporte de Escriba se conserva** pasándolo como `fetch` a cada
   proveedor:
   - la clave se tapa en errores y respuestas;
   - límite de tamaño de la respuesta, tiempo máximo y `redirect: "manual"`;
   - el `HttpTransport` inyectado con el que se prueba contra servidores
     falsos.
3. **Los errores se traducen como hoy.** Un 5xx, un 401, 403, 408 o 429, o un
   corte de red, son `backend_unavailable` (reintentable). El resto es
   `failed`. Los reintentos internos del SDK se apagan (`maxRetries: 0`),
   porque reintentar es cosa de la cola de trabajos.
4. **El resumen y las preguntas con esquema usan `generateObject`** con el JSON
   Schema que ya define cada receta (`jsonSchema(...)`). Un resumen vacío sigue
   siendo un error.
5. **La transcripción remota** usa el proveedor compatible con OpenAI. La
   función de transcripción del SDK es experimental: si no da los segmentos
   con tiempos de `verbose_json`, la transcripción sigue con la llamada actual.
   No se activa la diarización remota: «diarización sólo local» (`CLAUDE.md`).
6. **Primera vertical sin cambios visibles:** solo el proveedor compatible con
   OpenAI (`@ai-sdk/openai-compatible`), con las mismas pruebas de
   `remote.ts`, más una con un servidor que ignora `response_format`.

## Lo que necesita encargo aparte

- **Proveedores nativos** (Anthropic, Gemini, Mistral…) en el «+» de LLMs y STT.
  Es interfaz nueva y cambia la regla «los remotos hablan una API compatible
  con OpenAI» del `CLAUDE.md` y de la spec de recetas.
- **Streaming** del resumen hacia la interfaz o el Registro.
- **Herramientas** (tool calling) disponibles para recetas.

## Alternativas

- **Seguir con `remote.ts`.** Es poco código y funciona con lo que hay. Sin
  proveedores nativos, la ganancia del SDK es sobre todo la robustez de la
  salida estructurada.
- **Arreglar solo la salida estructurada a mano**: reintentar sin
  `response_format` y validar el JSON. Resuelve el fallo con Ollama sin
  dependencias, pero cada proveedor nuevo seguiría siendo trabajo propio.
- **Usar el SDK también en las recetas.** Descartada: les daría red y claves, y
  rompe el aislamiento.

## Consecuencias

- Dependencia nueva en el binario `escriba-runtime`, con versiones mayores
  frecuentes: se fija la versión y se actualiza a propósito, con la batería de
  `remote.ts` como red.
- Apple Intelligence sigue yendo por el host nativo, fuera del SDK. Se podría
  envolver como proveedor propio, pero no aporta nada hoy.
- Las credenciales siguen en ficheros privados `0600` del controlador. El SDK
  nunca lee variables de entorno de claves: cada proveedor recibe su clave al
  crearse.
- Afecta igual al Mac y a Linux, porque el controlador es común.
