public enum RecipeTemplate {
    public static let contract = ##"""
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

interface OpcionesDeTranscripcion {
  stt?: string
  idioma?: string | null
  hablantes?: { detectar: boolean; cuantos?: number | null }
}

interface OpcionesDeResumen {
  llm?: string
  prompt?: string | null
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
  readonly parametros: ParametrosDeReceta | null
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
"""##

    public static let tsconfig = ##"""
{
  "compilerOptions": {
    "target": "es2022",
    "lib": ["es2022"],
    "module": "es2022",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "types": []
  },
  "include": ["escriba-recetas.d.ts", "**/*.ts"]
}
"""##

    public static let agents = ##"""
# Recetas de Escriba

Este proyecto contiene recetas de Escriba: programas en TypeScript que deciden
qué pasa con cada grabación (transcribir, resumir, guardar y publicar).
Escriba compila este proyecto en cuanto cambia un fichero y ejecuta las
recetas por su cuenta. No hace falta instalar nada ni ejecutar ningún comando.

## Estructura

- `recetas/<clave>/receta.ts` es una receta. Su clave es el nombre de la
  carpeta.
- Cualquier otra carpeta (`comun/`, `lib/`…) es código compartido que las
  recetas importan.
- `escriba-recetas.d.ts` (los tipos del contrato) y `tsconfig.json` los
  escribió Escriba al crear el proyecto. Escriba no vuelve a escribir en esta
  carpeta salvo en `.escriba/`.
- `.escriba/estado.json` es el resultado de la última compilación.

## Contrato

Cada `receta.ts` exporta:

- `receta`: `{ nombre }`, el nombre que se ve en la app.
- `flujo(audio, escriba)`: una función asíncrona con todo el recorrido de una
  grabación.

Lo que puede pedir, con los tipos completos en `escriba-recetas.d.ts`:

- `escriba.transcribir(audio, { stt, idioma, hablantes })` devuelve la nota.
  Sin opciones, usa lo de la carpeta de la grabación.
- `nota.resumir({ llm, prompt })` añade título, resumen y etiquetas.
- `nota.guardar()` es obligatorio: una receta que termina sin guardar deja la
  nota fallida.
- `escriba.conector(claveONombre).publicar(nota)` publica en un conector.
- `escriba.stts`, `escriba.llms` y `escriba.conectores` listan lo configurado,
  con su clave, su nombre y su configuración, sin secretos.
- `escriba.log(texto)` escribe en la traza de la nota.

```ts
export const receta = { nombre: "Ideas" }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const nota = await escriba.transcribir(audio, { idioma: "es" })
  await nota.resumir({ prompt: "Tres viñetas, sin adornos" })
  await nota.guardar()
  await escriba.conector("Notion").publicar(nota)
}
```

## Reglas

- Solo se importan ficheros de este proyecto, con rutas relativas. Nada de
  paquetes de npm.
- Una receta no tiene red, disco ni temporizadores: solo ve el audio, la nota y
  `escriba`.
- Una receta puede ejecutar como mucho 10 segundos seguidos sin esperar a nada.
  Las esperas (transcribir, resumir, publicar) no cuentan.
- Si una receta deja de compilar, Escriba sigue con su último paquete bueno
  hasta que la arregles.

## Cómo comprobar tu trabajo

1. Guarda los ficheros.
2. Lee `.escriba/estado.json`. Cada receta aparece con su `clave`, su `nombre`,
   la huella del paquete que está en uso (`activa`) y sus `errores`.
3. Si la lista de errores de tu receta está vacía, compila y es la que está en
   uso. Si no, cada error dice fichero, línea, columna y qué falla.
"""##

    public static let starter = ##"""
export const receta = { nombre: "Mi receta" }

export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
  const nota = await escriba.transcribir(audio)
  await nota.resumir()
  await nota.guardar()
  for (const conector of escriba.conectores.filter((conector) => conector.activo)) {
    await escriba.conector(conector.clave).publicar(nota)
  }
}
"""##
}
