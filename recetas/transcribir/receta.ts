import { z } from "zod"
import { camposDeTranscripcion, transcribir } from "../piezas"

export const receta = { nombre: "Transcribir" }

export function buildRecipeForm(listas: ListasDeEscriba) {
  return z.object(camposDeTranscripcion(listas))
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const nota = await escriba.nota(audio)
  await transcribir(nota, escriba.parametros)
  await nota.guardar()
}
