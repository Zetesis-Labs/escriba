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
  Lo que no elijas va al local: Whisper, idioma automático y sin hablantes.
- `nota.resumir({ llm, prompt })` añade título, resumen y etiquetas. Sin
  `llm`, Apple Intelligence; sin `prompt`, el de serie.
- `nota.guardar()` es obligatorio: una receta que termina sin guardar deja la
  nota fallida.
- `escriba.conector(claveONombre).publicar(nota)` publica en un conector.
- `escriba.stts`, `escriba.llms` y `escriba.conectores` listan lo configurado,
  con su clave, su nombre y su configuración, sin secretos.
- `escriba.recetas` lista todas las recetas, las de este proyecto y las de
  formulario de la app, y `escriba.receta(claveONombre).procesar(audio)` le
  pasa la grabación a otra: hace su recorrido entero y su `guardar()` vale
  para las dos. Como mucho 4 recetas encadenadas y sin ciclos.
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
