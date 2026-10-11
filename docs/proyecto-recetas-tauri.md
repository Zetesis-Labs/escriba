# Proyectos de recetas en Escriba

Ampliación pedida por Rubén el 2026-10-10: proyecto TypeScript normal, herramientas
incluidas en la app y editor interno CodeMirror.

La ampliación del 2026-10-11 incorpora proveedores declarados por el proyecto,
formularios y credenciales gestionados por la app, y transporte autenticado
para SDK desde recetas. El contrato está implementado en la rama de trabajo;
la validación instalada por Rubén sigue pendiente. Véase
[el objetivo y sus criterios de aceptación](objetivo-extensibilidad-recetas.md).

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
La app actualiza sus copias administradas en `.escriba/deps` al cargar o preparar
el proyecto; **Dependencias** propaga esas versiones a `node_modules`. Los tipos
`escriba-recetas.d.ts` generados por la versión anterior se actualizan sólo si su
contenido sigue intacto; una copia editada por el usuario se conserva. Las fuentes
y dependencias propias del usuario no se reemplazan. Un proyecto antiguo que use opciones retiradas por TypeScript 7,
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

## Proveedores, cuentas y operaciones

`src/conectores.ts` puede exportar `inspect` y `run` desde
`createProgram(destinos, proveedores)`. Cada proveedor se crea con
`defineProvider`: su manifiesto declara ID, nombre, capacidad `http` o `folder`,
origen y cabeceras permitidas, definición de credencial si corresponde y
configuración inicial. Un esquema Zod valida esa configuración. `describe`
devuelve secciones, campos, acciones y vistas previas para el formulario común;
`action` puede obtener opciones del proveedor con la cuenta autorizada. El
estado de esas opciones es temporal y no contiene secretos. Notion y OKF usan
el mismo contrato que los proveedores externos. En el
[proyecto de ejemplo](../examples/conectores/README.md) hay una declaración
completa con opciones dinámicas.

La cuenta conserva la autorización concedida: proveedor, origen o carpeta,
cabeceras y credencial. El token se solicita y guarda por separado de los
campos del formulario. `api.cuenta(id).fetch` permite a una receta consultar y
modificar recursos mediante un SDK que acepte sustituir su transporte. Rust
comprueba en cada petición la cuenta activa y el alcance concedido, restringe
el origen y las cabeceras e inyecta la credencial. El programa recibe sólo las
respuestas del servicio. Un cambio de manifiesto no cambia la autorización de
una cuenta ya creada; el usuario debe conceder el nuevo alcance.

`api.conector(id).publicar(nota)` crea una publicación gestionada: Escriba
conserva su recibo y puede actualizarla o retirarla. Las llamadas arbitrarias
de `api.cuenta(id).fetch` son operaciones de cuenta; no generan por sí solas
un recibo ni entran en ese ciclo. Si una escritura de la receta termina sin
confirmación, Escriba detiene el reintento automático hasta que el usuario
reprocesa manualmente. OAuth, SDK que exigen red directa o transporte no
sustituible, y recuperación automática de cualquier efecto arbitrario no forman
parte de este contrato.

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
