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

interface Nota {
  readonly clave: string
  readonly version: number | null
  readonly texto: string
  readonly hablantes: readonly string[]
  readonly segmentos: readonly Segmento[]
  readonly resumen: Resumen | null
  resumir(): Promise<Nota>
  guardar(): Promise<Nota>
}

interface Conector {
  readonly clave: string
  publicar(nota: Nota): Promise<void>
}

interface Escriba {
  readonly conectores: readonly string[]
  transcribir(audio: Audio): Promise<Nota>
  conector(clave: string): Conector
  log(texto: string): void
}

interface ErrorDeEscriba extends Error {
  readonly codigo: "no-disponible" | "fallo"
}
