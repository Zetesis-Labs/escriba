let preludeSource = #"""
(() => {
  "use strict"
  const puente = globalThis.__puente
  delete globalThis.__puente
  const lista = (json) => Object.freeze(JSON.parse(json).map((elemento) => Object.freeze(elemento)))
  const stts = lista(puente.stts)
  const llms = lista(puente.llms)
  const conectores = lista(puente.conectores)
  const recetas = lista(puente.recetas)
  const opciones = (valor) => JSON.stringify(valor ?? {})
  const congelar = (valor) => {
    if (valor && typeof valor === "object") Object.values(valor).forEach(congelar)
    return Object.freeze(valor)
  }
  const parametros = congelar(JSON.parse(puente.parametros))
  const formatear = (valor) => {
    if (typeof valor === "string") return valor
    if (valor instanceof Error) return `${valor.name}: ${valor.message}`
    try {
      const json = JSON.stringify(valor, null, 2)
      return json === undefined ? String(valor) : json
    } catch {
      return String(valor)
    }
  }
  const escribir = (nivel) => (...valores) => puente.log(nivel, valores.map(formatear).join(" "))
  Object.defineProperty(globalThis, "console", {
    value: Object.freeze({
      log: escribir("info"),
      info: escribir("info"),
      warn: escribir("warn"),
      error: escribir("error"),
      debug: escribir("debug"),
    }),
  })
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

    async resumir(pedido) {
      Object.assign(this, JSON.parse(await pedir(puente.resumir(opciones(pedido)))))
      return this
    }

    async guardar() {
      await pedir(puente.guardar())
      return this
    }
  }

  const escriba = Object.freeze({
    parametros,
    stts,
    llms,
    conectores,
    recetas,
    async transcribir(audio, pedido) {
      return new Nota(JSON.parse(await pedir(puente.transcribir(opciones(pedido)))))
    },
    conector(referencia) {
      const texto = String(referencia)
      const info =
        conectores.find((conector) => conector.clave === texto) ??
        conectores.find((conector) => conector.nombre.toLowerCase() === texto.toLowerCase())
      return Object.freeze({
        clave: info?.clave ?? texto,
        nombre: info?.nombre ?? texto,
        tipo: info?.tipo ?? null,
        async publicar(nota) {
          await pedir(puente.publicar(texto))
        },
      })
    },
    receta(referencia) {
      const texto = String(referencia)
      const info =
        recetas.find((receta) => receta.clave === texto) ??
        recetas.find((receta) => receta.nombre.toLowerCase() === texto.toLowerCase())
      return Object.freeze({
        clave: info?.clave ?? texto,
        nombre: info?.nombre ?? texto,
        tipo: info?.tipo ?? null,
        async procesar(audio) {
          await pedir(puente.procesar(texto))
        },
      })
    },
    log(texto) {
      puente.log("info", String(texto))
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
      return \#(packageProblemFunction)(globalThis.__receta)
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
