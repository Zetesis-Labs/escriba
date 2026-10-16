import { z } from "zod"
import { camposDePublicacion, camposDeResumen, camposDeTranscripcion, publicar, resumir, transcribir } from "../piezas"

export const receta = { nombre: "Por defecto" }

export function buildRecipeForm(listas: ListasDeEscriba) {
  return z.object({
    ...camposDeTranscripcion(listas),
    resumir: z.boolean().default(true).meta({ title: "Resumir" }),
    ...camposDeResumen(listas, "resumir"),
    ...camposDePublicacion(listas),
  })
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const parametros = escriba.parametros
  const nota = await escriba.nota(audio)
  await transcribir(nota, parametros)
  if (parametros.resumir) {
    try {
      await resumir(nota, parametros)
    } catch (error) {
      console.warn(`no se pudo resumir: ${error}`)
    }
  }
  await nota.guardar()
  await publicar(nota, escriba, parametros)
}
