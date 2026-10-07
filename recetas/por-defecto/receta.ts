export const receta = { nombre: "Por defecto" }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const nota = await escriba.transcribir(audio)
  await nota.resumir()
  await nota.guardar()
  for (const conector of escriba.conectores) {
    try {
      await escriba.conector(conector.clave).publicar(nota)
    } catch (error) {
      escriba.log(`no se pudo publicar en ${conector.nombre}: ${error}`)
    }
  }
}
