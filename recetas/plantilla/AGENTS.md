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
  validan al guardar. La biblioteca los enseña en el detalle de la nota.
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
  cliente: z.string().nullable().describe("La empresa del cliente, si se menciona"),
  tareas: z.array(z.string()),
  urgente: z.boolean(),
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
