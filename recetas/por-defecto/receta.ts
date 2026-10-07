export const receta = { nombre: "Por defecto" }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const parametros = escriba.parametros
  if (!parametros) throw new Error("la receta por defecto necesita los parámetros de su formulario")
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
