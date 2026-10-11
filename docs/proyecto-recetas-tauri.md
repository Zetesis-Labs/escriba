# Proyectos de recetas en Escriba

Ampliación pedida por Rubén el 2026-10-10: proyecto TypeScript normal, herramientas
incluidas en la app y editor interno CodeMirror.

Ampliación confirmada el 2026-10-11, aún pendiente: proveedores declarados por
el proyecto con formularios y credenciales gestionados por la app, y transporte
autenticado para usar SDK directamente desde las recetas. Véase
[el objetivo y sus criterios de aceptación](objetivo-extensibilidad-recetas.md).
El contrato descrito a continuación corresponde a lo implementado actualmente.

## Editar y construir

En Recetas, elegir una carpeta vacía crea el proyecto y sus tipos. Abrir editor
muestra los archivos y permite crear otros, editar y guardar con ⌘S. Los cambios
sin guardar se conservan al volver a Recetas durante la sesión; hay que guardarlos
antes de ejecutar una herramienta. Si un editor externo cambió el archivo, el
guardado falla conservando el borrador para evitar sobrescribirlo.
Recargar vuelve a leer el archivo y pide confirmación antes de descartar un
borrador; si la lectura falla, conserva los cambios.

El playground incluye estas acciones:

- **Dependencias:** `bun install --ignore-scripts`, con caché dentro de `.escriba`.
  Ejecutarlo antes de comprobar tipos o pruebas en un proyecto nuevo.
- **Comprobar tipos:** TypeScript 7.0.2 nativo en Go, `tsc --noEmit` sobre `tsconfig.json`.
- **Pruebas:** `bun test` sobre el proyecto.
- **Construir:** Bun empaqueta las recetas y conectores en `dist/`; después Escriba
  inspecciona los programas y actualiza su catálogo.

Las herramientas están encima del código. **Abrir en VS Code** abre la carpeta
completa del proyecto en Visual Studio Code, si está instalado en el Mac; no
requiere instalar el comando `code` en el terminal. La consola permanece debajo
del editor.

El editor ofrece sintaxis TypeScript y completado básico de CodeMirror. Los errores
del comprobador aparecen en la consola; no se integra un servidor de lenguaje.
No hace falta instalar Node, Bun, npm ni Go en el equipo. Go solo es el lenguaje
en el que está compilado el comprobador distribuido. El proyecto nuevo incluye
también las declaraciones de Bun y Node para comprobar tests TypeScript e
imports de módulos integrados.

```text
mi-proyecto/
  package.json
  tsconfig.json
  escriba-recetas.d.ts
  src/
    conectores.ts
    recetas/ejemplo/receta.ts
  node_modules/
  .escriba/                 # dependencias administradas, caché y temporales
  dist/
    escriba.json
    receta-0.js
    conectores.js
```

Las recetas también pueden estar en la estructura anterior `recetas/<id>/receta.ts`
y el conector en `conectores.ts`. La variante `src/recetas/<id>` conserva el mismo
ID. Se rechazan IDs duplicados. En otras carpetas, el ID se deriva de la ruta con
prefijo `code:`. `receta.ts` prevalece sobre `receta.js` en la misma carpeta.

El proyecto puede importar paquetes ESM, CommonJS y JSON de su `node_modules`.
Su versión de Zod prevalece; si falta, el constructor usa la incluida. Zod y
`@escriba/conectores` tienen una copia administrada y están declarados como
dependencias `file:` en el proyecto nuevo, que se puede preparar sin descargar
paquetes. Se pueden cambiar por las versiones npm que necesite el proyecto.
Los archivos existentes del usuario no se reemplazan al elegir
la carpeta. Un proyecto antiguo que use opciones retiradas por TypeScript 7,
como `baseUrl`, debe actualizar su `tsconfig.json`; el comprobador informa el error.

La app genera también el lanzador `./escriba`, con los comandos `install`,
`check`, `test` y `build`. Usa los mismos ejecutables y perfiles que el editor.
Al cargar el proyecto, Escriba actualiza las rutas de su lanzador administrado
si la aplicación ha cambiado de ubicación. Los proyectos existentes conservan sus propios archivos.

## Contrato de distribución

Escriba carga únicamente `dist/escriba.json` y los JavaScript que declara. Acepta
un proyecto con `dist/` y sin fuentes ni dependencias. Elegirlo no añade un ejemplo.
El manifiesto de versión 1 tiene esta forma:

```json
{
  "version": 1,
  "recipes": [
    {
      "id": "ejemplo",
      "name": "Ejemplo",
      "entry": "src/recetas/ejemplo/receta.ts",
      "file": "receta-0.js"
    }
  ],
  "connectors": "conectores.js"
}
```

`connectors` es opcional. `entry` identifica la fuente para el editor, pero no tiene
que existir al cargar. Las rutas de `file` y `connectors` son relativas a `dist`;
no se permiten enlaces ni escapes. Cada paquete registra sus exports en
`globalThis.__recipe` o `globalThis.__conectores`. El constructor incluido genera
CommonJS empaquetado y lo envuelve para ese contrato. El runtime aporta `require`
solo para módulos integrados de Node; las dependencias npm deben ir empaquetadas.

El constructor genera un directorio temporal antes de sustituir `dist`. Un error
de empaquetado conserva el artefacto anterior. Si la posterior inspección de
exports, formularios o destinos falla, se conserva el catálogo instalado; `dist`
contiene la última compilación y la consola informa por qué no se pudo instalar.
Construir no comprueba tipos: es una acción separada, igual que en Bun.

Los cambios de fuentes guardadas disparan una construcción. Los cambios de
`dist` solo lo recargan. `.escriba`, `.git` y `node_modules` no disparan builds.
Las construcciones y la instalación de su catálogo se atienden en orden para
que el watcher y el botón Construir no se adelanten entre sí.

## Aislamiento y compatibilidad

El proceso de construcción y las herramientas pueden leer el proyecto y las
dependencias incluidas, y escribir dentro del proyecto. Solo la instalación
permite red; los scripts de instalación de paquetes están desactivados. Desde el
editor, las herramientas tienen un límite de 60 segundos y 64 KiB de salida;
el lanzador de terminal usa el mismo aislamiento, sin esos límites de consola.
Las recetas sobre notas
corren en otros procesos sin permisos de archivos, red ni subprocesos: usan las
capacidades de Escriba. Los tokens y las rutas de audio siguen en Rust.

El artefacto no conserva módulos npm externos, chunks ni archivos auxiliares.
Paquetes que necesitan binarios nativos, archivos en tiempo de ejecución o imports
dinámicos cuyo destino no se puede empaquetar no son compatibles con este contrato.
Las APIs puras de Node disponibles en Bun, como `node:path` o los hashes de
`node:crypto`, pueden usarse. Instalar un paquete no concede permisos nuevos.

El entorno de desarrollo de Escriba usa Bun fijado en
`apps/tauri/runtime-host/bun-version`; el checker de recetas está fijado en
`apps/tauri/runtime-host/toolchain/package-lock.json`. El TypeScript usado para
compilar la interfaz de la app es una dependencia de desarrollo distinta.
