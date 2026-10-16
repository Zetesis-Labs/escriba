import { z } from "zod"
import { camposDeResumen, notaTranscrita, resumir } from "../piezas"

export const receta = { nombre: "Resumir", parte: "nota" }

export function buildRecipeForm(listas: ListasDeEscriba) {
  return z.object(camposDeResumen(listas))
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const nota = await notaTranscrita(audio, escriba)
  await resumir(nota, escriba.parametros)
  await nota.guardar()
}
