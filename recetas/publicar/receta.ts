import { z } from "zod"
import { camposDePublicacion, notaTranscrita, publicar } from "../piezas"

export const receta = { nombre: "Publicar" }

export function buildRecipeForm(listas: ListasDeEscriba) {
  return z.object(camposDePublicacion(listas))
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const nota = await notaTranscrita(audio, escriba)
  await nota.guardar()
  const fallos = await publicar(nota, escriba, escriba.parametros)
  if (fallos.length) throw fallos[0]
}
