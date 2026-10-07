interface Audio {
  readonly clave: string
  readonly nombre: string
  readonly fecha: string
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
  readonly favorito: boolean
}

interface InfoDeConector {
  readonly clave: string
  readonly nombre: string
  readonly tipo: "notion" | "okf"
}

interface OpcionesDeTranscripcion {
  stt?: string
  idioma?: string | null
  hablantes?: { detectar: boolean; cuantos?: number }
}

interface OpcionesDeResumen {
  llm?: string
  prompt?: string
}

interface Nota {
  readonly clave: string
  readonly version: number | null
  readonly texto: string
  readonly hablantes: readonly string[]
  readonly segmentos: readonly Segmento[]
  readonly resumen: Resumen | null
  resumir(opciones?: OpcionesDeResumen): Promise<Nota>
  guardar(): Promise<Nota>
}

interface Conector {
  readonly clave: string
  readonly nombre: string
  readonly tipo: "notion" | "okf" | null
  publicar(nota: Nota): Promise<void>
}

interface Escriba {
  readonly stts: readonly Resolutor[]
  readonly llms: readonly Resolutor[]
  readonly conectores: readonly InfoDeConector[]
  transcribir(audio: Audio, opciones?: OpcionesDeTranscripcion): Promise<Nota>
  conector(claveONombre: string): Conector
  log(texto: string): void
}

interface ErrorDeEscriba extends Error {
  readonly codigo: "no-disponible" | "fallo"
}
