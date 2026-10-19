interface Origen {
  readonly tipo: "bandeja" | "carpeta"
  readonly nombre: string
  readonly ruta: string
}

interface Audio {
  readonly clave: string
  readonly nombre: string
  readonly fecha: string
  readonly origen: Origen | null
}

interface Palabra {
  readonly inicio: number
  readonly fin: number
  readonly texto: string
}

interface Segmento {
  readonly inicio: number
  readonly fin: number
  readonly hablante: string | null
  readonly texto: string
  readonly palabras: readonly Palabra[]
}

interface Resumen {
  readonly titulo: string
  readonly texto: string
  readonly etiquetas: readonly string[]
}

interface Resolutor {
  readonly clave: string
  readonly nombre: string
  readonly local: boolean
  readonly modelo: string | null
  readonly url: string | null
}

interface InfoDeConector {
  readonly clave: string
  readonly nombre: string
  readonly tipo: string
  readonly activo: boolean
}

interface InfoDeReceta {
  readonly clave: string
  readonly nombre: string
  readonly tipo: "formulario" | "codigo"
}

interface InfoDeCuenta {
  readonly clave: string
  readonly nombre: string
  readonly tipo: string
  readonly activo: boolean
  readonly origen: string | null
}

interface Cuenta {
  readonly clave: string
  readonly nombre: string
  readonly fetch: typeof fetch
}

interface OpcionesDeTranscripcion {
  stt?: string
  idioma?: string | null
  hablantes?: { detectar: boolean; cuantos?: number | null }
}

interface OpcionesDeResumen {
  llm?: string
  prompt?: string | null
}

interface EsquemaDeZod<T = unknown> {
  readonly "~standard": {
    readonly validate: (valor: unknown) => unknown
    readonly types?: { readonly output: T } | undefined
  }
}

interface Pregunta {
  entrada: string
  instrucciones?: string
  llm?: string
}

interface PreguntaConEsquema<T> extends Pregunta {
  esquema: EsquemaDeZod<T>
}

interface InfoDeVersion {
  readonly clave: string
  readonly numero: number
  readonly fecha: string
  readonly origen: "receta" | "correccion"
  readonly receta: string | null
  readonly vigente: boolean
  readonly abierta: boolean
  readonly criterios: OpcionesDeTranscripcion | null
  readonly tiene: { readonly hablantes: boolean; readonly resumen: boolean; readonly datos: boolean }
}

interface OpcionesDeNota {
  version?: string
  editar?: boolean
}

interface Nota {
  readonly clave: string
  readonly version: number | null
  readonly origen: number | null
  readonly texto: string
  readonly hablantes: readonly string[]
  readonly segmentos: readonly Segmento[]
  readonly resumen: Resumen | null
  datos: Record<string, unknown> | null
  transcribir(opciones?: OpcionesDeTranscripcion): Promise<Nota>
  resumir(opciones?: OpcionesDeResumen): Promise<Nota>
  guardar(cambios?: { datos?: Record<string, unknown> | null }): Promise<Nota>
  vincular(ontologiaId: string, registroId: string): Promise<void>
}

interface Conector {
  readonly clave: string
  readonly nombre: string
  readonly tipo: string | null
  publicar(nota: Nota): Promise<void>
}

interface Receta {
  readonly clave: string
  readonly nombre: string
  readonly tipo: "formulario" | "codigo" | null
  procesar(audio: Audio): Promise<void>
}

interface ListasDeEscriba {
  readonly stts: readonly Resolutor[]
  readonly llms: readonly Resolutor[]
  readonly conectores: readonly InfoDeConector[]
  readonly recetas: readonly InfoDeReceta[]
  readonly cuentas?: readonly InfoDeCuenta[]
}

/** Un LLM remoto para el AI SDK (`ai` 7). Llama por Escriba: la receta nunca ve su clave. */
interface ModeloDeLenguaje {
  readonly specificationVersion: "v4"
  readonly provider: "escriba"
  readonly modelId: string
  readonly supportedUrls: Record<string, RegExp[]>
  doGenerate(opciones: any): PromiseLike<any>
  doStream(opciones: any): PromiseLike<any>
}

interface Escriba<P = null> extends ListasDeEscriba {
  readonly parametros: P
  transcribir(audio: Audio, opciones?: OpcionesDeTranscripcion): Promise<Nota>
  nota(audio: Audio, opciones?: OpcionesDeNota): Promise<Nota>
  versiones(audio: Audio): Promise<readonly InfoDeVersion[]>
  preguntar<T>(pedido: PreguntaConEsquema<T>): Promise<T>
  preguntar(pedido: Pregunta): Promise<string>
  conector(claveONombre: string): Conector
  cuenta(claveONombre: string): Cuenta
  grafo(ontologiaId: string): Promise<import("surrealdb").Surreal>
  receta(claveONombre: string): Receta
  modelo(claveONombre: string): ModeloDeLenguaje
  log(texto: string): void
}

interface DependenciaDeOntologia {
  readonly id: string
  readonly minVersion: number
  readonly maxVersion: number
}

interface ReferenciaDeConocimiento {
  readonly ontologyId: "escriba"
  readonly table: string
  readonly id: string
}

interface CampoDeConocimiento {
  readonly key: string
  readonly label: string
  readonly type: "text" | "number" | "boolean" | "date" | "json" | "reference"
  readonly required?: boolean
  readonly reference?: { readonly ontologyId: "escriba"; readonly table: ReferenciaDeConocimiento["table"] }
}

interface ColeccionDeConocimiento {
  readonly table: string
  readonly label: string
  readonly titleField: string
  readonly fields: readonly CampoDeConocimiento[]
  readonly relation?: { readonly from: string; readonly to: string }
}

interface Ontologia {
  readonly id: string
  readonly name: string
  readonly version: number
  readonly migrations: readonly { readonly version: number; readonly sql: string }[]
  readonly collections: readonly ColeccionDeConocimiento[]
}

interface ErrorDeEscriba extends Error {
  readonly codigo: "no-disponible" | "fallo"
}

declare const console: {
  log(...valores: unknown[]): void
  info(...valores: unknown[]): void
  warn(...valores: unknown[]): void
  error(...valores: unknown[]): void
  debug(...valores: unknown[]): void
}
