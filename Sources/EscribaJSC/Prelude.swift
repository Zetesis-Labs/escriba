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
  const camino = (partes) =>
    (partes ?? []).map((parte) => String(typeof parte === "object" && parte !== null ? parte.key : parte)).join(".")
  const validar = async (esquema, valor, que) => {
    const resultado = await esquema["~standard"].validate(valor)
    if (!resultado.issues) return resultado.value
    const detalle = resultado.issues.map((problema) => `${camino(problema.path) || "raíz"}: ${problema.message}`)
    const error = new Error(`${que} con el esquema: ${detalle.join("; ")}`)
    error.codigo = "fallo"
    throw error
  }
  const esquemaJSON = (esquema) => {
    try {
      return JSON.stringify(esquema["~standard"].jsonSchema?.output({ target: "draft-2020-12" }) ?? null)
    } catch {
      return null
    }
  }
  const leerNota = (texto) => {
    const { datosJSON, ...campos } = JSON.parse(texto)
    return { campos, datosJSON: datosJSON ?? "null" }
  }
  const pendientes = new Map()
  const pedir = (id) => new Promise((resolve, reject) => pendientes.set(id, { resolve, reject }))
  const soltar = (id) => {
    const pendiente = pendientes.get(id)
    pendientes.delete(id)
    return pendiente
  }

  class Nota {
    #guardados

    constructor(texto) {
      const { campos, datosJSON } = leerNota(texto)
      Object.assign(this, campos)
      this.datos = JSON.parse(datosJSON)
      this.#guardados = datosJSON
    }

    async resumir(pedido) {
      Object.assign(this, leerNota(await pedir(puente.resumir(opciones(pedido)))).campos)
      return this
    }

    async guardar(cambios) {
      if (cambios && Object.hasOwn(cambios, "datos")) this.datos = cambios.datos ?? null
      const esquema = globalThis.__receta.receta.datos
      if (this.datos != null && esquema) this.datos = await validar(esquema, this.datos, "los datos de la nota no casan")
      const texto = JSON.stringify(this.datos ?? null)
      const cambiados = texto !== this.#guardados
      await pedir(puente.guardar(cambiados ? texto : null, cambiados && esquema ? esquemaJSON(esquema) : null))
      this.#guardados = texto
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
      return new Nota(await pedir(puente.transcribir(opciones(pedido))))
    },
    async preguntar(pedido) {
      if (!pedido || typeof pedido.entrada !== "string") throw new TypeError("preguntar necesita { entrada: texto }")
      const esquema = pedido.esquema ?? null
      let jsonSchema = null
      if (esquema !== null) {
        const estandar = esquema["~standard"]
        if (typeof estandar?.validate !== "function" || typeof estandar.jsonSchema?.output !== "function") {
          throw new TypeError("el esquema de preguntar tiene que ser de Zod: z.object({ … })")
        }
        jsonSchema = JSON.stringify(estandar.jsonSchema.output({ target: "draft-2020-12" }))
      }
      const pregunta = JSON.stringify({ llm: pedido.llm, instrucciones: pedido.instrucciones, entrada: pedido.entrada })
      const respuesta = JSON.parse(await pedir(puente.preguntar(pregunta, jsonSchema)))
      return esquema === null ? respuesta : validar(esquema, respuesta, "la respuesta del LLM no casa")
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
