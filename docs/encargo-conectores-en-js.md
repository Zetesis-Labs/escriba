# Encargo para Codex: investigar los conectores como librerías de JavaScript

Encargado por Rubén el 2026-10-08. Es una **investigación**: el entregable es
un análisis con preguntas abiertas y, si ayuda, un spike desechable. No se
cambia el código de la app ni se abre PR; Rubén decide después.

## La idea de Rubén

> Los conectores no tienen sentido en Swift; tendrían más sentido como
> librerías de JS puras que te instalas en tu repo de scripts. En la app
> vinculas tu cuenta de Notion u otras cuentas externas. OKF no necesita
> configuración para funcionar. Las librerías tendrían un builder para
> construir de forma declarativa los formularios que hoy se construyen en la
> app. Hay que separar el almacenamiento de la cuenta remota de la
> configuración del destino. Mejor declarativo: en la interfaz no se edita,
> solo se ven los destinos que expones y qué datos aceptan, y luego tus recetas
> los usan. Puede ser mucho lío.

## Qué hay hoy

- **Conectores en Swift**:
  - `Sources/EscribaNotion/`: cliente, esquema, columnas, carga, cuerpo en bloques, paginación, 429, preview; unas 1.300 líneas.
  - `Sources/EscribaOKF/`: bundle OKF v0.2 en una carpeta; unas 750 líneas.
  - Modelos en `Sources/EscribaModel/`: `ConnectorsModel`, `Connector`, `NotionModel`, `NotionAccount` (token en el Llavero) y `OKFModel`.
  - Editores de mapeo en `Sources/EscribaMenuBar/OKFEditor.swift`, `TokenEditor.swift` y `SettingsView.swift` (`ConnectorsPane`).
- **Publicar**:
  - Las recetas llaman a `escriba.conector(clave).publicar(nota)` (`Sources/EscribaJSC/Prelude.swift`), que va por el puente a `RecipeSession.publish` (`Sources/EscribaEngine/RecipeSession.swift`).
  - Fuera de una receta, `LibraryModel.publish`, `republish` (al corregir hablantes o cambiar el resumen) y `unpublish` (`Sources/EscribaModel/LibraryModel.swift`).
- **Recetas**:
  - Proyecto en TypeScript en una carpeta del usuario, compilado con esbuild en WebAssembly a un paquete de un solo fichero que ejecuta JavaScriptCore. JavaScriptCore no tiene módulos.
  - De npm solo se importa `zod`.
  - Los formularios ya son declarativos: `buildRecipeForm(listas)` devuelve un esquema de Zod, la app lo convierte a JSON Schema y lo pinta (`Sources/EscribaCore/RecipeForm.swift`).
  - El contrato está en `recetas/escriba-recetas.d.ts`.
- **Lo aprobado hasta ahora**: el RF-9 de `docs/requisito-recetas.md` dice lo **contrario** a la idea nueva. El conector se queda en Swift con lo difícil (credencial, destino, tipos de columna, bloques, paginación, 429, regenerar la página, rastro de publicación) y la receta solo decide la carga. La fase 5 de `docs/roadmap.md` añade como propuesta que el conector sea la cuenta y su alcance, y la receta elija el destino dentro.

Lee antes `CLAUDE.md` (sobre todo recetas, conectores, Personas y las reglas
de commits), `docs/requisito-recetas.md` (RF-4, RF-4b, RF-6, RF-9, RF-16 a
RF-18) y `docs/roadmap.md`.

## Reglas que no se negocian

1. **El JavaScript nunca ve tokens ni claves, ni cambia la configuración**
   (Rubén). Una librería de conector en JS no puede guardar ni leer el token de
   Notion.
2. Computación local: no sale nada del Mac salvo lo que el usuario publica. Las
   huellas de voz (Personas) no salen nunca.
3. De npm solo entra `zod`, salvo que el análisis justifique otra vía y
   Rubén la apruebe.
4. Núcleo funcional y cáscara imperativa: las decisiones, en funciones puras con
   test (swift-testing, nombres en español).

## Preguntas que tiene que responder el análisis

1. **La frontera.** Qué se queda en Swift y qué pasa a JS.
   - Probablemente se quedan la cuenta, el transporte autenticado limitado a un dominio, la escritura limitada a una carpeta y el rastro de publicación.
   - Probablemente pasan la carga, el mapeo y los destinos.
   - ¿Y los reintentos con 429 y la paginación?
2. **La capacidad autenticada.** Cómo sería `escriba.cuenta("notion").pedir(...)`, o lo que proponga, sin que el JS pueda sacar el token:
   - alcance por dominio y método;
   - cabeceras que nunca se devuelven;
   - qué respuestas ve el JS;
   - límites.
   Lo mismo para OKF: escribir solo dentro de la carpeta vinculada.
3. **Lo declarativo.** Cómo declara una librería sus destinos y qué datos acepta, con Zod como `buildRecipeForm`, para que la app los enseñe en solo lectura.
   - Dónde vive la configuración del destino (el id de la base de Notion, la ruta dentro de OKF): en el código del proyecto o en la app.
   - Cómo se valida contra la cuenta real.
4. **El ciclo de vida fuera de una receta.** Al corregir hablantes, resumir a mano o borrar una nota, hoy Swift regenera o borra la página. Con conectores en JS:
   - ¿cómo ejecuta la app ese código sin una receta en marcha?
   - ¿y qué pasa si el proyecto de recetas no compila en ese momento?
   Es el punto que Rubén intuye como «mucho lío».
5. **La distribución.** Cómo llegan las librerías al proyecto del usuario:
   - copiadas por la plantilla;
   - traídas por la app como Zod;
   - o un paquete propio.
   Y cómo se versionan.
6. **La migración.** Qué pasa con los conectores ya configurados: Notion con su mapeo de columnas, OKF con sus N documentos.
7. **El coste y la recomendación.** Compara tres caminos, con estimación por fases, riesgos y una recomendación razonada:
   - el RF-9 tal cual;
   - la idea de Rubén entera;
   - un punto intermedio.

## Entregable

- `docs/requisito-conectores-js.md`. Debe incluir:
  - la comparación;
  - la frontera;
  - el API de capacidades escrito como tipos de TypeScript (al estilo de `escriba-recetas.d.ts`);
  - el ciclo de vida, la migración y las fases con criterios de salida;
  - las preguntas abiertas para Rubén.
  Sin decidir por él lo que es suyo.
- Opcional, si hace falta para responder la pregunta 2: un spike desechable en `spikes/conector-js/`. Que demuestre que un JS ejecutado en JavaScriptCore pide algo a una cuenta y Swift pone la cabecera, **contra un servidor local falso**.
- Trabaja en la rama `docs/encargo-conectores-js`, donde está este encargo, o en una tuya creada desde ella. Commits sin trailer de Claude ni de Codex, con rebase y nunca merge.

## Fuera de alcance

- No tocar `Sources/` ni `Tests/`, salvo el spike aislado.
- No llamar a la API real de Notion, no leer tokens del Llavero, no publicar nada.
- No abrir PR ni mergear: el análisis vuelve a Rubén.
