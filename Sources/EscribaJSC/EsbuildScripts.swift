import EscribaCore

let packageProblemFunction = #"""
((receta) => {
  if (typeof receta !== "object" || receta === null) return "no define ninguna receta"
  if (typeof receta.flujo !== "function") return "falta la función flujo"
  if (typeof receta.receta !== "object" || receta.receta === null || typeof receta.receta.nombre !== "string")
    return "falta receta.nombre"
  const datos = receta.receta.datos
  if (datos !== undefined && typeof datos?.["~standard"]?.validate !== "function")
    return "receta.datos tiene que ser un esquema de Zod: z.object({ … })"
  const formulario = receta.\#(recipeFormExport)
  if (formulario !== undefined && typeof formulario !== "function")
    return "\#(recipeFormExport) tiene que ser una función que devuelva un esquema de Zod"
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
  const normalizar = partes => {
    const salida = []
    for (const parte of partes) {
      if (!parte || parte === ".") continue
      if (parte === "..") { if (!salida.length) throw new Error("la ruta escapa del proyecto"); salida.pop() }
      else salida.push(parte)
    }
    return salida.join("/")
  }
  const proyecto = archivos => ({
    name: "proyecto",
    setup(build) {
      const exists = p => Object.prototype.hasOwnProperty.call(archivos,p)
      const manifest = p => exists(p + "/package.json") ? JSON.parse(archivos[p + "/package.json"]) : {}
      const file = p => [p,p+".ts",p+".tsx",p+".js",p+".mjs",p+".cjs",p+".json",p+"/index.ts",p+"/index.js",p+"/index.mjs",p+"/index.cjs"].find(exists)
      const condition = (value, kind) => {
        if (typeof value === "string") return value
        if (Array.isArray(value)) { for (const option of value) { const found = condition(option,kind); if(found)return found } }
        if (value && typeof value === "object") for (const [key,target] of Object.entries(value)) if (["browser",kind === "require-call" ? "require" : "import","default"].includes(key)) { const found=condition(target,kind);if(found)return found }
        return null
      }
      const resolvePackage = (specifier,importer,kind) => {
        const pieces=specifier.split('/'), name=specifier.startsWith('@') ? pieces.slice(0,2).join('/') : pieces[0]
        const suffix=pieces.slice(name.startsWith('@')?2:1).join('/'), sub=suffix?'./'+suffix:'.'
        let base=importer.split('/').slice(0,-1)
        while(true) {
          const root=[...base,'node_modules',name].join('/').replace(/^\//,'')
          if(exists(root+'/package.json')) {
            const pkg=manifest(root);let target
            if(pkg.exports!==undefined) {
              const exports=pkg.exports
              if(typeof exports==='object' && exports!==null && !Array.isArray(exports) && Object.keys(exports).some(k=>k.startsWith('.'))) {
                target=condition(exports[sub],kind)
                if(!target) for(const key of Object.keys(exports).filter(k=>k.includes('*')).sort((a,b)=>b.length-a.length)) {
                  const [start,end]=key.split('*');if(sub.startsWith(start)&&sub.endsWith(end)){const found=condition(exports[key],kind);if(found){target=found.replaceAll('*',sub.slice(start.length,end?-end.length:undefined));break}}
                }
              } else if(sub==='.') target=condition(exports,kind)
              if(!target || !target.startsWith('./'))throw new Error(`«${specifier}» no se exporta para este runtime`)
            } else target=suffix || (typeof pkg.browser==='string'?pkg.browser:pkg.module || pkg.main || 'index.js')
            const path=normalizar([...root.split('/'),...target.split('/')])
            if(!path.startsWith(root+'/'))throw new Error('exports escapa del paquete')
            const found=file(path);if(!found)throw new Error(`falta «${path}» en el paquete instalado`)
            return found
          }
          if(!base.length)return null
          base.pop()
        }
      }
      build.onResolve({filter:/.*/}, args => {
        try {
          if(args.kind==='entry-point') { const path=normalizar(args.path.split('/'));if(args.path.startsWith('/'))throw new Error('entrada absoluta no permitida');return {path,namespace:'proyecto'} }
          if(args.namespace==='zod') {
            if(!args.path.startsWith('.'))throw new Error('import de Zod no compatible')
            const path=normalizar([...args.importer.split('/').slice(0,-1),...args.path.split('/')])
            return globalThis.__zod(path)!=null?{path,namespace:'zod'}:{errors:[{text:`zod no trae «${args.path}»`}]}
          }
          if(args.path==='crypto' && args.kind==='require-call')return {path:'crypto',namespace:'unavailable-node'}
          if(args.path.startsWith('/') || args.path.includes('\\') || args.path.includes(':') || args.path.startsWith('#'))throw new Error(`import no compatible con el host: «${args.path}»`)
          let found
          if(args.path.startsWith('.'))found=file(normalizar([...args.importer.split('/').slice(0,-1),...args.path.split('/')]))
          else found=resolvePackage(args.path,args.importer,args.kind)
          if(found)return {path:found,namespace:'proyecto'}
          if(args.path==='zod' && globalThis.__zod('index.js')!=null)return {path:'index.js',namespace:'zod'}
          return {errors:[{text:args.path.startsWith('.') ? `no existe «${args.path}» en el proyecto` : `no existe «${args.path}» en el proyecto ni en node_modules; instala sus dependencias npm`}]}
        } catch(error) { return {errors:[{text:String(error)}]} }
      })
      build.onLoad({filter:/.*/,namespace:'proyecto'}, args=>({contents:archivos[args.path],loader:args.path.endsWith('.json')?'json':/\.[cm]?js$/.test(args.path)?'js':args.path.endsWith('.tsx')?'tsx':'ts'}))
      build.onLoad({filter:/.*/,namespace:'unavailable-node'},()=>({contents:"throw new Error('El host no ofrece crypto de Node; la verificación de webhooks requiere una capacidad criptográfica explícita')",loader:'js'}))
      build.onLoad({filter:/.*/,namespace:'zod'},args=>({contents:globalThis.__zod(args.path),loader:'js'}))
    }
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
      const { archivos, entrada, global = "__receta" } = JSON.parse(peticion)
      return esbuild
        .build({
          entryPoints: [entrada], bundle: true, write: false, format: "iife", globalName: global,
          target: "es2022", charset: "utf8", logLevel: "silent", logOverride: { "unsupported-dynamic-import": "error", "unsupported-require-call": "error" }, plugins: [proyecto(archivos)],
          sourcemap: "external", outfile: "receta.js",
        })
        .then(
          (resultado) => {
            const codigo = resultado.outputFiles.find((salida) => salida.path.endsWith(".js"))
            const mapa = resultado.outputFiles.find((salida) => salida.path.endsWith(".map"))
            return JSON.stringify({ codigo: codigo?.text, mapa: mapa?.text ?? null })
          },
          (fallo) => JSON.stringify({ errores: (fallo.errors ?? [{ text: String(fallo) }]).map(error) }),
        )
    },
  }
})()
"""#
