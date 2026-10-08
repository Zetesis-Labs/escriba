# Recetas de Escriba

Este proyecto contiene recetas de Escriba: programas en TypeScript que deciden
qué pasa con cada grabación (transcribir, resumir, guardar y publicar).
Escriba compila este proyecto en cuanto cambia un fichero y ejecuta las
recetas por su cuenta. No hace falta instalar nada ni ejecutar ningún comando.

## Estructura

- `recetas/<clave>/receta.ts` es una receta. Su clave es el nombre de la
  carpeta.
- Cualquier otra carpeta (`comun/`, `lib/`…) es código compartido que las
  recetas importan.
- `escriba-recetas.d.ts` (los tipos del contrato) y `tsconfig.json` los
  escribió Escriba al crear el proyecto. Escriba no vuelve a escribir en esta
  carpeta salvo en `.escriba/`.
- `.escriba/estado.json` es el resultado de la última compilación.
- `.escriba/zod/` son los tipos de Zod que trae Escriba, para el editor.

## Contrato

Cada `receta.ts` exporta:

- `receta`: `{ nombre, datos? }`, el nombre que se ve en la app y, si quieres,
  el esquema de Zod de los datos que guarda (ver más abajo).
- `flujo(audio, escriba)`: una función asíncrona con todo el recorrido de una
  grabación.
- `buildRecipeForm(listas)`, si quieres que la receta tenga parámetros que se
  cambian desde la app (ver «Parámetros» más abajo).

Lo que puede pedir, con los tipos completos en `escriba-recetas.d.ts`:

- `audio.origen` dice de dónde viene la grabación: `{ tipo, nombre, ruta }`,
  con `tipo` `"bandeja"` (grabada o añadida en Escriba) o `"carpeta"` (una
  carpeta vigilada, con su nombre: «Notas de Voz», «Just Press Record»…), o
  `null` si ya no cae en ninguna. Sirve para repartir:
  `if (audio.origen?.nombre === "Notas de Voz") return escriba.receta("Reuniones").procesar(audio)`.
- `escriba.transcribir(audio, { stt, idioma, hablantes })` devuelve la nota.
  Lo que no elijas va al local: Whisper, idioma automático y sin hablantes.
- `nota.resumir({ llm, prompt })` añade título, resumen y etiquetas. Sin
  `llm`, Apple Intelligence; sin `prompt`, el de serie.
- `nota.guardar()` es obligatorio: una receta que termina sin guardar deja la
  nota fallida.
- `escriba.preguntar({ esquema, entrada, instrucciones, llm })` pregunta a un
  LLM y devuelve un objeto con la forma de `esquema`, un `z.object` de Zod, ya
  validado: si el LLM contesta otra cosa, es un error y nunca llegan datos a
  medias. Sin `esquema` devuelve texto. Sin `llm`, Apple Intelligence, que
  solo admite unos 3500 caracteres de `entrada` e `instrucciones`: para
  notas largas, pregunta sobre `nota.resumen.texto` o usa un LLM remoto. La
  misma pregunta sobre la misma versión de la nota se recuerda y no se repite.
- `nota.datos` son los datos propios de la nota, un objeto JSON o `null`, y se
  guardan con la versión: `await nota.guardar({ datos })` o cambiando
  `nota.datos` y llamando a `guardar()`. Si `receta.datos` es un esquema, se
  validan al guardar. La biblioteca los enseña en el detalle de la nota, con
  la etiqueta que pongas en el esquema con `.meta({ title: "En una frase" })`
  o, si no hay, con la clave tal cual; lo que es `null` o está vacío no sale.
- `escriba.conector(claveONombre).publicar(nota)` publica en un conector.
- `escriba.stts`, `escriba.llms` y `escriba.conectores` listan lo configurado,
  con su clave, su nombre y su configuración, sin secretos.
- `escriba.recetas` lista todas las recetas, las de este proyecto y las de
  formulario de la app, y `escriba.receta(claveONombre).procesar(audio)` le
  pasa la grabación a otra: hace su recorrido entero y su `guardar()` vale
  para las dos. Como mucho 4 recetas encadenadas y sin ciclos.
- `console.log`, `info`, `warn`, `error` y `debug` (y `escriba.log(texto)`,
  que es como `console.log`) escriben en la traza de la nota con su nivel; un
  objeto sale como JSON. Escriba guarda cada ejecución con sus pasos y su log,
  y se ven en la ficha de la receta y en la sección Registro.

```ts
export const receta = { nombre: "Ideas" }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const nota = await escriba.transcribir(audio, { idioma: "es" })
  await nota.resumir({ prompt: "Tres viñetas, sin adornos" })
  await nota.guardar()
  await escriba.conector("Notion").publicar(nota)
}
```

```ts
import { z } from "zod"

const Reunion = z.object({
  cliente: z.string().nullable().meta({ title: "Cliente" }).describe("La empresa del cliente, si se menciona"),
  tareas: z.array(z.string()).meta({ title: "Tareas" }),
  urgente: z.boolean().meta({ title: "Urgente" }),
})

export const receta = { nombre: "Reuniones", datos: Reunion }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const nota = await escriba.transcribir(audio, { idioma: "es" })
  const datos = await escriba.preguntar({ esquema: Reunion, entrada: nota.texto })
  if (datos.urgente) await escriba.conector("Notion").publicar(nota)
  await nota.guardar({ datos })
}
```

Los esquemas de `preguntar` admiten objetos, textos, números, enteros,
booleanos, listas, enumerados, nulos, opcionales y descripciones
(`.describe()`, que el LLM lee). No admiten `z.record`, `z.tuple`, uniones de
tipos distintos ni esquemas recursivos, porque los LLM no saben responder a
eso: la receta recibe un error que dice dónde está.

## Parámetros

Una receta con `buildRecipeForm` tiene un formulario en la app: Escriba lo
pinta en la ficha de la receta y en «Reprocesar con…», y lo que el usuario
cambia ahí se guarda para esa receta. `buildRecipeForm` recibe las mismas
listas que `escriba` (`stts`, `llms`, `conectores` y `recetas`) para construir
las opciones con lo que hay configurado, y devuelve un `z.object` de Zod.

```ts
import { z } from "zod"

export const receta = { nombre: "Reuniones" }

export function buildRecipeForm({ llms }: ListasDeEscriba) {
  return z.object({
    idioma: z.enum(["es", "en"]).nullable().default("es").meta({ title: "Idioma" }).describe("Vacío: lo detecta"),
    hablantes: z
      .object({
        detectar: z.boolean().default(false).meta({ title: "Detectar hablantes" }),
        cuantos: z.number().int().min(2).max(6).nullable().default(null).meta({ title: "Cuántos" }),
      })
      .prefault({})
      .meta({ title: "Hablantes" }),
    llm: z
      .union(llms.map((llm) => z.literal(llm.clave).meta({ title: llm.nombre })))
      .default("apple")
      .meta({ title: "Resume con" }),
  })
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const { idioma, hablantes, llm } = escriba.parametros
  const nota = await escriba.transcribir(audio, { idioma, hablantes })
  await nota.resumir({ llm })
  await nota.guardar()
}
```

- Al ejecutar, `escriba.parametros` son los valores guardados pasados por el
  esquema, con los de serie rellenos. Si un valor guardado ya no vale (por
  ejemplo, un LLM que se quitó de la lista), la ejecución falla diciendo qué
  campo, y la ficha lo marca: nunca se cambia por otro en silencio.
- El valor de serie de cada campo es su `.default()`; «Volver a los valores
  del script» deshace lo que haya cambiado el usuario. Un campo sin
  `.default()` es obligatorio y la ficha avisa hasta que tenga valor.
- Para un grupo de campos (un `z.object` dentro de otro) usa `.prefault({})`
  y no `.default({})`: con `.default({})` Zod no rellena los valores de serie
  de dentro.
- La etiqueta de cada campo sale de `.meta({ title })` y la ayuda de
  `.describe()`. Un texto largo, como un prompt, se pide con
  `.meta({ title: "Prompt", lineas: 6 })`: sale un cuadro de esas líneas. Un desplegable de `z.enum` enseña los valores tal cual; para
  que enseñe nombres, usa `z.union` de `z.literal(clave).meta({ title: nombre })`
  como arriba.
- El formulario pinta interruptores (booleanos), desplegables (enumerados,
  uniones de literales y enteros con mínimo y máximo cercanos), casillas
  (`z.array(z.enum(…))`), campos de texto y de número, y grupos. No pinta
  `z.record`, `z.tuple`, listas de texto libre ni uniones de tipos distintos:
  la ficha dice cuál es el campo.
- Una lista puede venir vacía (por ejemplo, sin conectores): un desplegable
  sin opciones se ve vacío, así que hazlo `.nullable().default(null)`.
- Los cambios de «Reprocesar con…» valen solo para esa vez y solo para la
  receta elegida; si esta pasa la grabación a otra con `procesar`, la otra usa
  sus valores guardados.
- `buildRecipeForm` no es asíncrona ni espera a nada, y sin ella
  `escriba.parametros` es `null`.

## Reglas

- Solo se importan ficheros de este proyecto, con rutas relativas, y `zod`, que
  trae Escriba (la versión 4). Nada más de npm.
- Una receta no tiene red, disco ni temporizadores: solo ve el audio, la nota y
  `escriba`.
- Una receta puede ejecutar como mucho 10 segundos seguidos sin esperar a nada.
  Las esperas (transcribir, resumir, publicar) no cuentan.
- Si una receta deja de compilar, Escriba sigue con su último paquete bueno
  hasta que la arregles.

## Cómo comprobar tu trabajo

1. Guarda los ficheros.
2. Lee `.escriba/estado.json`. Cada receta aparece con su `clave`, su `nombre`,
   la huella del paquete que está en uso (`activa`) y sus `errores`.
3. Si la lista de errores de tu receta está vacía, compila y es la que está en
   uso. Si no, cada error dice fichero, línea, columna y qué falla.
