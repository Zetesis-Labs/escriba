import { z } from "zod"

z.config(z.locales.es())

function opciones(elementos: readonly { clave: string; nombre: string }[]) {
  return z.union(elementos.map((elemento) => z.literal(elemento.clave).meta({ title: elemento.nombre })))
}

function local(resolutores: readonly Resolutor[]): string {
  return (resolutores.find((resolutor) => resolutor.local) ?? resolutores[0]).clave
}

function cuando(si: string | undefined) {
  return si ? { si } : {}
}

export function camposDeTranscripcion({ stts }: ListasDeEscriba) {
  return {
    stt: opciones(stts).default(local(stts)).meta({ title: "Transcribe con" }),
    idioma: z
      .union([z.literal("es").meta({ title: "Español" }), z.literal("en").meta({ title: "English" })])
      .nullable()
      .default("es")
      .meta({ title: "Idioma" })
      .describe("Vacío: lo detecta en cada nota"),
    hablantes: z
      .object({
        detectar: z
          .boolean()
          .default(false)
          .meta({ title: "Detectar hablantes" })
          .describe("Solo con Whisper en este equipo"),
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
  }
}

export function camposDeResumen({ llms }: ListasDeEscriba, si?: string) {
  return {
    // Without LLMs, summarizing fails visibly and the note is kept.
    llm: (llms.length ? opciones(llms).default(local(llms)) : opciones(llms).nullable().default(null)).meta({
      title: "Resume con",
      ...cuando(si),
    }),
    prompt: z
      .string()
      .nullable()
      .default(null)
      .meta({ title: "Prompt", lineas: 6, ...cuando(si) })
      .describe("Vacío: el de serie"),
  }
}

export function camposDePublicacion({ conectores }: ListasDeEscriba) {
  return {
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
  }
}

export type ValoresDeTranscripcion = z.output<z.ZodObject<ReturnType<typeof camposDeTranscripcion>>>
export type ValoresDeResumen = z.output<z.ZodObject<ReturnType<typeof camposDeResumen>>>
export type ValoresDePublicacion = z.output<z.ZodObject<ReturnType<typeof camposDePublicacion>>>

export function transcribir(nota: Nota, { stt, idioma, hablantes }: ValoresDeTranscripcion) {
  return nota.transcribir({ stt, idioma, hablantes })
}

export async function notaTranscrita<P>(audio: Audio, escriba: Escriba<P>): Promise<Nota> {
  const nota = await escriba.nota(audio)
  if (nota.version === null) throw Error("La nota aún no está transcrita")
  return nota
}

export function resumir(nota: Nota, { llm, prompt }: ValoresDeResumen) {
  return nota.resumir({ llm: llm ?? undefined, prompt })
}

export async function publicar<P>(nota: Nota, escriba: Escriba<P>, { conectores }: ValoresDePublicacion) {
  const fallos: unknown[] = []
  for (const clave of conectores) {
    try {
      await escriba.conector(clave).publicar(nota)
    } catch (error) {
      console.warn(`no se pudo publicar en ${clave}: ${error}`)
      fallos.push(error)
    }
  }
  return fallos
}
