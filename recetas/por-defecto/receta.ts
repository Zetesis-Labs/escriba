import { z } from "zod"

z.config(z.locales.es())

export const receta = { nombre: "Por defecto" }

function opciones(elementos: readonly { clave: string; nombre: string }[]) {
  return z.union(elementos.map((elemento) => z.literal(elemento.clave).meta({ title: elemento.nombre })))
}

function local(resolutores: readonly Resolutor[]): string {
  return (resolutores.find((resolutor) => resolutor.local) ?? resolutores[0]).clave
}

export function buildRecipeForm({ stts, llms, conectores }: ListasDeEscriba) {
  return z.object({
    stt: opciones(stts).default(local(stts)).meta({ title: "Transcribe con" }),
    idioma: z
      .union([z.literal("es").meta({ title: "Español" }), z.literal("en").meta({ title: "English" })])
      .nullable()
      .default(null)
      .meta({ title: "Idioma" })
      .describe("Vacío: lo detecta en cada nota"),
    hablantes: z
      .object({
        detectar: z
          .boolean()
          .default(false)
          .meta({ title: "Detectar hablantes" })
          .describe("Solo con Whisper en este Mac"),
        cuantos: z
          .number()
          .int()
          .min(2)
          .max(6)
          .nullable()
          .default(null)
          .meta({ title: "Cuántos", si: "detectar" })
          .describe("Vacío: los que salgan"),
      })
      .prefault({})
      .meta({ title: "Hablantes" }),
    resumir: z.boolean().default(false).meta({ title: "Resumir" }),
    llm: opciones(llms).default(local(llms)).meta({ title: "Resume con", si: "resumir" }),
    prompt: z
      .string()
      .nullable()
      .default(null)
      .meta({ title: "Prompt", lineas: 6, si: "resumir" })
      .describe("Vacío: el de serie"),
    conectores: z
      .array(
        z.union(
          conectores.map((conector) =>
            z.literal(conector.clave).meta({ title: conector.activo ? conector.nombre : `${conector.nombre} (apagado)` }),
          ),
        ),
      )
      .default([])
      .meta({ title: "Publica en" }),
  })
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const parametros = escriba.parametros
  const nota = await escriba.transcribir(audio, {
    stt: parametros.stt,
    idioma: parametros.idioma,
    hablantes: parametros.hablantes,
  })
  if (parametros.resumir) await nota.resumir({ llm: parametros.llm, prompt: parametros.prompt })
  await nota.guardar()
  for (const clave of parametros.conectores) {
    try {
      await escriba.conector(clave).publicar(nota)
    } catch (error) {
      escriba.log(`no se pudo publicar en ${clave}: ${error}`)
    }
  }
}
