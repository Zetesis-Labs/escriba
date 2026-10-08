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
  readonly tipo: "notion" | "okf"
  readonly activo: boolean
  readonly base: { readonly id: string; readonly nombre: string } | null
  readonly carpeta: string | null
}

interface InfoDeReceta {
  readonly clave: string
  readonly nombre: string
  readonly tipo: "formulario" | "codigo"
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

interface ParametrosDeReceta {
  readonly stt: string
  readonly idioma: string | null
  readonly hablantes: { readonly detectar: boolean; readonly cuantos: number | null }
  readonly resumir: boolean
  readonly llm: string
  readonly prompt: string | null
  readonly conectores: readonly string[]
}

interface Nota {
  readonly clave: string
  readonly version: number | null
  readonly texto: string
  readonly hablantes: readonly string[]
  readonly segmentos: readonly Segmento[]
  readonly resumen: Resumen | null
  datos: Record<string, unknown> | null
  resumir(opciones?: OpcionesDeResumen): Promise<Nota>
  guardar(cambios?: { datos?: Record<string, unknown> | null }): Promise<Nota>
}

interface Conector {
  readonly clave: string
  readonly nombre: string
  readonly tipo: "notion" | "okf" | null
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
}

interface Escriba<P = ParametrosDeReceta | null> extends ListasDeEscriba {
  readonly parametros: P
  transcribir(audio: Audio, opciones?: OpcionesDeTranscripcion): Promise<Nota>
  preguntar<T>(pedido: PreguntaConEsquema<T>): Promise<T>
  preguntar(pedido: Pregunta): Promise<string>
  conector(claveONombre: string): Conector
  receta(claveONombre: string): Receta
  log(texto: string): void
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
