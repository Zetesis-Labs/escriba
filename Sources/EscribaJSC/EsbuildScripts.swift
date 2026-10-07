let packageProblemFunction = #"""
((receta) => {
  if (typeof receta !== "object" || receta === null) return "no define ninguna receta"
  if (typeof receta.flujo !== "function") return "falta la función flujo"
  if (typeof receta.receta !== "object" || receta.receta === null || typeof receta.receta.nombre !== "string")
    return "falta receta.nombre"
  return ""
})
"""#

let inspectionSource = #"""
(() => {
  const problema = \#(packageProblemFunction)(globalThis.__receta)
  return JSON.stringify(problema ? { problema } : { nombre: globalThis.__receta.receta.nombre })
})()
"""#

let esbuildPolyfills = #"""
var self = globalThis
globalThis.console = { log: () => {}, warn: () => {}, error: () => {} }
globalThis.performance = { now: () => Date.now() }
globalThis.crypto = {
  getRandomValues(array) {
    for (let i = 0; i < array.length; i++) array[i] = Math.floor(Math.random() * 256)
    return array
  },
}
globalThis.TextEncoder = class {
  encode(texto = "") {
    const binario = unescape(encodeURIComponent(texto))
    const bytes = new Uint8Array(binario.length)
    for (let i = 0; i < binario.length; i++) bytes[i] = binario.charCodeAt(i)
    return bytes
  }
}
globalThis.TextDecoder = class {
  decode(vista) {
    if (!vista) return ""
    const bytes = vista instanceof Uint8Array ? vista : new Uint8Array(vista.buffer ?? vista, vista.byteOffset ?? 0, vista.byteLength)
    let binario = ""
    for (let i = 0; i < bytes.length; i += 8192) binario += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192))
    return decodeURIComponent(escape(binario))
  }
}
const temporizadores = new Map()
let siguienteTemporizador = 1
globalThis.setTimeout = (funcion, ms, ...args) => {
  const id = siguienteTemporizador++
  temporizadores.set(id, () => funcion(...args))
  __programar(id, ms || 0)
  return id
}
globalThis.clearTimeout = (id) => {
  temporizadores.delete(id)
}
globalThis.__disparar = (id) => {
  const funcion = temporizadores.get(id)
  temporizadores.delete(id)
  if (funcion) funcion()
}
"""#

let esbuildDriver = #"""
(() => {
  const normalizar = (partes) => {
    const salida = []
    for (const parte of partes) {
      if (parte === "" || parte === ".") continue
      if (parte === "..") salida.pop()
      else salida.push(parte)
    }
    return salida.join("/")
  }

  const proyecto = (archivos) => ({
    name: "proyecto",
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (args.kind === "entry-point") return { path: args.path, namespace: "proyecto" }
        if (!args.path.startsWith(".")) {
          return { errors: [{ text: `solo se importan ficheros del proyecto, con rutas relativas: «${args.path}»` }] }
        }
        const base = args.importer.split("/").slice(0, -1)
        const ruta = normalizar([...base, ...args.path.split("/")])
        const encontrada = [ruta, ruta + ".ts", ruta + ".js", ruta + "/index.ts", ruta + "/index.js"]
          .find((candidata) => candidata in archivos)
        return encontrada
          ? { path: encontrada, namespace: "proyecto" }
          : { errors: [{ text: `no existe «${args.path}» en el proyecto` }] }
      })
      build.onLoad({ filter: /.*/, namespace: "proyecto" }, (args) => ({
        contents: archivos[args.path],
        loader: args.path.endsWith(".js") ? "js" : "ts",
      }))
    },
  })

  const error = (e) => ({
    fichero: e.location ? e.location.file.replace(/^proyecto:/, "") : null,
    linea: e.location ? e.location.line : null,
    columna: e.location ? e.location.column : null,
    texto: e.text,
  })

  return {
    arrancar: () => esbuild.initialize({ wasmModule: globalThis.__modulo, worker: false }),
    compilar: (peticion) => {
      const { archivos, entrada } = JSON.parse(peticion)
      return esbuild
        .build({
          entryPoints: [entrada], bundle: true, write: false, format: "iife", globalName: "__receta",
          target: "es2022", charset: "utf8", logLevel: "silent", plugins: [proyecto(archivos)],
        })
        .then(
          (resultado) => JSON.stringify({ codigo: resultado.outputFiles[0].text }),
          (fallo) => JSON.stringify({ errores: (fallo.errors ?? [{ text: String(fallo) }]).map(error) }),
        )
    },
  }
})()
"""#
