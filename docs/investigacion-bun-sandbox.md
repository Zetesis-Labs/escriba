# Bun compilado y aislamiento de recetas en macOS

Investigación del 2026-10-10 para la puerta 4 de `pendiente-tauri.md`. Se refiere al ejecutable que aloja el controlador y a cada proceso de receta; Rust sigue siendo dueño de las capacidades y del audio. No se ejecutaron recetas ni se accedió a datos del usuario.

## Hechos comprobados

- `bun build --compile` incorpora los imports resueltos y el runtime Bun en un ejecutable autónomo; hay targets `bun-darwin-arm64` y `bun-darwin-x64`. **No es una barrera de permisos**: las APIs de Bun/Node siguen disponibles y un recurso o import no incluido puede buscarse en disco respecto al directorio de trabajo. Los `Worker` que se lancen con la API de Bun requieren incluir su entrada en el build. [Bun: ejecutables](https://bun.sh/docs/bundler/executables).
- Bun usa JavaScriptCore. Su documentación describe JIT y ajustes de política, pero no certifica que un ejecutable compilado arranque con un perfil concreto de `sandbox-exec`, ni enumera sus lecturas de sistema, servicios Mach o permisos de memoria ejecutable. Esa lista debe salir de pruebas en macOS 26 con el binario distribuido. [Bun: runtime](https://bun.sh/docs/runtime), [Bun: ejecutables, JIT](https://bun.sh/docs/bundler/executables#jit-policy).
- El protocolo existente de Escriba es JSON por `stdin`/`stdout`; Bun expone los flujos estándar y su API de procesos documenta `pipe` para entrada y salida. Su IPC es un canal **adicional**, opcional y orientado a procesos Bun: no hace falta activarlo para el padre Rust. Bun documenta señales, salida y cancelación; Rust debe conservar sus límites de trama, plazo, cierre y espera del hijo. [Bun: spawn](https://bun.sh/docs/runtime/child-process), [Bun: señales](https://bun.sh/guides/process/os-signals).
- Un ejecutable compilado carga `.env` y `bunfig.toml` del directorio de ejecución por defecto. `--no-compile-autoload-dotenv` y `--no-compile-autoload-bunfig` lo desactivan desde **Bun 1.3.3**; `tsconfig.json` y `package.json` dejan de cargarse por defecto desde 1.3.4. `BUN_OPTIONS` cambia los argumentos del binario compilado y `BUN_BE_BUN=1` lo convierte en la CLI de Bun: limpiar el entorno sigue siendo imprescindible. [Bun 1.3.3](https://bun.com/blog/bun-v1.3.3#control-env-and-bunfigtoml-loading-in-standalone-executables), [Bun 1.4, cambio de 1.3.4](https://bun.sh/blog/bun-v1.4), [Bun: configuración y modo CLI](https://bun.sh/docs/bundler/executables#automatic-config-loading).
- Sin `node_modules`, Bun puede instalar un import no resuelto en su caché durante la ejecución. El runtime ofrece `--no-install`; `--compile-exec-argv="--no-install"` permite incorporarlo al ejecutable. `bunfig` admite `[install] auto="disable"`, pero depender de leer `bunfig.toml` en ejecución contradice desactivar su carga. Compilar todas las dependencias y rechazar imports externos es la primera barrera; denegar red y escritura es la segunda. [Bun: auto-install](https://bun.sh/docs/runtime/auto-install), [Bun: opciones runtime](https://bun.sh/docs/runtime), [Bun: argumentos compilados](https://bun.sh/docs/bundler/executables#embedding-runtime-arguments).
- En el Mac examinado, `sandbox-exec(1)` y `sandbox_init(3)` están marcados **DEPRECATED** en los manuales de macOS 26; Apple remite a App Sandbox. `sandbox(7)` aclara que las restricciones suelen aplicarse al adquirir recursos: un descriptor ya abierto puede seguir usándose. Los perfiles `.sb` del sistema advierten que son interfaz privada cambiante. Esta solución exige una prueba de compatibilidad por release de macOS y fallo cerrado si el perfil no se aplica; no equivale a prometer una API estable de Apple. Fuentes locales: `man sandbox-exec`, `man sandbox`, `man sandbox_init`, `/System/Library/Sandbox/Profiles/`; [Apple: App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

## Superficie mínima propuesta

Rust lanza **cada** proceso (controlador y receta) bajo perfil `deny default`, con ejecutable y perfil de ruta fija verificados, `env_clear`, directorio de trabajo sin proyecto ni configuración, y únicamente los descriptores necesarios para `stdin`, `stdout` y `stderr` (los demás cerrados antes del lanzamiento). No se conceden red, sockets, acceso al home, notas, carpeta de recetas, caché npm, temporales de usuario, escritura general, ni `process-fork`/`process-exec` adicional. El padre entrega por el protocolo solo las capacidades autorizadas; las rutas, tokens y bytes de audio no se transfieren. `sandbox(7)` (manual local de Apple) explica por qué filtrar los FD importa además del perfil.

El perfil debe conceder solamente la ejecución inicial del binario compilado y las lecturas del propio binario y bibliotecas **del sistema** que una prueba sintética demuestre necesarias. `otool -L` del Bun local 1.3.0 muestra `libicucore`, `libresolv`, `libc++` y `libSystem`, pero no prueba los requisitos del Bun compilado 1.4.2. No abrir `/Users`, `/Library`, `/private`, `/tmp` ni servicios Mach por comodidad. En particular, una excepción `process-exec` para el propio binario podría permitir relanzarlo con `posix_spawn`; el test debe demostrar que `Bun.spawn`/`node:child_process` siguen denegados. Las peticiones necesarias para JavaScriptCore/JIT se miden y justifican una a una, sin una regla comodín.

## Versión y puerta de verificación

El Bun previamente instalado era **1.3.0** y su `bun build --help` no ofrecía los interruptores de autoload; no hay workaround oficial verificado para esa versión. La versión fijada para esta investigación es **1.4.2**: [release y assets oficiales](https://github.com/oven-sh/bun/releases/tag/bun-v1.4.2), [ZIP macOS arm64](https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-darwin-aarch64.zip), SHA-256 `90987a3a16d7db556d886ac3d551e7b6d3edf0a1cf43acaed622e8676be1d12f` según [assets de la release](https://github.com/oven-sh/bun/releases/expanded_assets/bun-v1.4.2). Fijar esa versión y hash en build/CI y verificar que el ejecutable final mantiene las opciones elegidas.

Antes de dar por válida la migración, ejercer con código sintético el protocolo y cancelación existentes, el arranque JSC bajo el perfil, y negativas de lectura de fichero privado, escritura, conexión de red y proceso hijo. Confirmar que `.env`/`bunfig.toml` colocados en el cwd de prueba no alteran la ejecución y que un import externo falla sin instalación. Una denegación requerida por el runtime se añade al perfil solo con la ruta/operación observada; si exige acceso amplio a datos o red, la puerta no pasa.

## Límite de memoria comprobado

`BUN_JSC_gcMaxHeapSize=536870912` **no equivale** a un límite de heap de 512 MiB. La opción existe en [JavaScriptCore](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/OptionsList.h), pero un colaborador de Bun aclara que solo dispara la recolección, sin imponer un tope. En el [reporte de Bun #34917](https://github.com/oven-sh/bun/issues/34917) se reproducen asignaciones por encima de `BUN_JSC_gcMaxHeapSize`, `--max-old-space-size` y `--smol`; el 7 de octubre otro usuario reprodujo el fallo en Bun 1.4.3-canary.1 sobre macOS ARM64. Además, una prueba local sintética de Bun **1.4.2** compilado y firmado retuvo 128 arrays de aproximadamente 1 MiB con `BUN_JSC_gcMaxHeapSize=67108864` y terminó con código 0. Por tanto, ninguna de esas opciones puede acreditarse como protección para las recetas.

Un límite sobre el heap JavaScript tampoco acotaría por sí mismo toda la memoria residente: [Bun documenta dos heaps](https://bun.sh/docs/project/benchmarking#measuring-memory-usage), el de JavaScript y el nativo. Rust mide RSS mediante `proc_pidinfo` cada 50 ms y termina el worker si observa
más de 512 MiB. La prueba de exceso sintético pasó y el controlador continuó
respondiendo. Es un límite operativo por observación y terminación, con posible
exceso entre muestras, no una cuota estricta ni paridad exacta con el heap del
antiguo runtime Deno. Las pruebas de procesos también comprobaron que ni
`Bun.spawnSync` ni `node:child_process` pueden relanzar el mismo ejecutable.

## ICU en el perfil mínimo

La construcción de una receta funcionaba, pero ordenar varias con `localeCompare`
terminaba Bun con SIGKILL. Un fixture idéntico reprodujo el fallo con Python y
Rust, descartando stdin, firma y el lanzador. Autorizar solo `/usr/share/icu`
lo resolvió; autorizar metadatos, `/dev`, `/private`, `/Library`, `/Users`,
`/System`, `/usr/share/locale` o `/usr/share/zoneinfo` no. Son los datos de
internacionalización del sistema, necesarios para el comparador de texto.
El perfil de desarrollo y el de recetas permiten leer esa ruta concreta.
La prueba de una receta con `localeCompare('es')` falló antes con
«failed to initialize Collator». No se concedieron servicios Mach ni lectura
general de `/usr/share`.

El constructor necesita además metadatos de los enlaces `/var` y `/tmp` cuando
un paquete del proyecto apunta a otra carpeta suya mediante esos alias de
macOS. Una prueba con `node_modules/@escriba/conectores` enlazado dentro del
proyecto fallaba con EPERM; autorizar solo `file-read-metadata` sobre el literal
`/var` la hizo pasar. Se permiten únicamente esos dos literales en desarrollo,
no su contenido ni un subárbol fuera del proyecto.
