let preludeSource = #"""
(() => {
  "use strict"
  const puente = globalThis.__puente
  delete globalThis.__puente
  const conectores = Object.freeze(JSON.parse(puente.conectores))
  const pendientes = new Map()
  const pedir = (id) => new Promise((resolve, reject) => pendientes.set(id, { resolve, reject }))
  const soltar = (id) => {
    const pendiente = pendientes.get(id)
    pendientes.delete(id)
    return pendiente
  }

  class Nota {
    constructor(datos) {
      Object.assign(this, datos)
    }

    async resumir() {
      Object.assign(this, JSON.parse(await pedir(puente.resumir())))
      return this
    }

    async guardar() {
      await pedir(puente.guardar())
      return this
    }
  }

  const escriba = Object.freeze({
    conectores,
    async transcribir(audio) {
      return new Nota(JSON.parse(await pedir(puente.transcribir())))
    },
    conector(clave) {
      return Object.freeze({
        clave: String(clave),
        async publicar(nota) {
          await pedir(puente.publicar(String(clave)))
        },
      })
    },
    log(texto) {
      puente.log(String(texto))
    },
  })

  return {
    resolver(id, valor) {
      soltar(id).resolve(valor)
    },
    rechazar(id, error) {
      soltar(id).reject(error)
    },
    error(mensaje, codigo, token) {
      const error = new Error(mensaje)
      error.codigo = codigo
      Object.defineProperty(error, "__token", { value: token })
      return error
    },
    validar() {
      const receta = globalThis.__receta
      if (typeof receta !== "object" || receta === null) return "no define ninguna receta"
      if (typeof receta.flujo !== "function") return "falta la función flujo"
      if (typeof receta.receta !== "object" || receta.receta === null || typeof receta.receta.nombre !== "string")
        return "falta receta.nombre"
      return ""
    },
    ejecutar(audio, fin, fallo) {
      let resultado
      try {
        resultado = globalThis.__receta.flujo(Object.freeze(JSON.parse(audio)), escriba)
      } catch (error) {
        fallo(error)
        return
      }
      Promise.resolve(resultado).then(() => fin(), (error) => fallo(error))
    },
  }
})()
"""#
