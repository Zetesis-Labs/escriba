export const receta = { nombre: "Mi receta" }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const nota = await escriba.transcribir(audio)
  await nota.resumir()
  await nota.guardar()
  for (const conector of escriba.conectores.filter((conector) => conector.activo)) {
    await escriba.conector(conector.clave).publicar(nota)
  }
}
