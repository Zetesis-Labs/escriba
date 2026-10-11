# Proveedores y SDK desde el proyecto de recetas

Objetivo confirmado por Rubén el 2026-10-11. Ampliación del proyecto TypeScript
aprobado y del [ADR-0001](adr/0001-conectores-en-typescript.md).
**Implementación completada; pendiente de validación instalada por Rubén.** Este
documento conserva los criterios de aceptación y registra el contrato implementado.
Las pruebas automatizadas no sustituyen los recorridos manuales con la app instalada.

## Resultado esperado

El usuario puede añadir un proveedor desde su proyecto de recetas, instalar sus
dependencias con las herramientas Bun de Escriba y construir el `dist/` que carga
la app. No necesita editar el repositorio de Escriba, recompilar la aplicación
ni esperar una versión nueva por cada proveedor.

Monday fue sólo un ejemplo de Rubén, no un conector encargado ni un requisito
de entrega. El objetivo es la extensibilidad para cualquier proveedor compatible
con el contrato, no una lista de integraciones que implementar en Escriba.

El proyecto declara la configuración y los formularios del conector, las
credenciales que necesita y el acceso que solicita. Escriba muestra esos
formularios, recoge las credenciales por un canal separado de los parámetros
ordinarios y conserva la autorización del usuario. Cargar código no concede
acceso ni permite cambiar en silencio una autorización existente.

Una receta puede utilizar el SDK de un proveedor con una cuenta autorizada para
consultar y modificar sus recursos. No queda limitada a `publicar(nota)`.
El SDK utiliza un transporte compatible proporcionado por Escriba; el token
real permanece en el host y no entra en la receta, sus parámetros, el artefacto
distribuible ni los registros.

Los términos cuenta, conector, destino, publicación y operación de cuenta están
definidos en [CONTEXT.md](../CONTEXT.md). Las publicaciones conservan su ciclo
actual de actualización y retirada; una consulta o acción arbitraria del SDK
no se presenta automáticamente como una publicación gestionada por Escriba.

## Contrato implementado

El proyecto exporta `inspect` y `run` desde `src/conectores.ts`; Escriba carga su
artefacto en `dist/conectores.js`. `defineProvider` registra el manifiesto, el
esquema Zod de configuración ordinaria, `describe`, las acciones del formulario
y las operaciones del proveedor. `createProgram(destinos, proveedores)` conserva
los destinos existentes y añade las declaraciones de proveedores. `inspect()`
devuelve ambos catálogos. La app usa el mismo renderizador de `ConnectorView`
para Notion, OKF y proveedores externos: campos con rutas de configuración,
opciones y vistas previas proceden del programa. `describe` calcula la vista sin
acceso al host; `action` puede consultar o modificar el servicio al pulsar un
control y devolver configuración y estado temporal. Esas acciones explícitas no
se encolan ni se repiten al renderizar, reiniciar o recuperar trabajos. La
credencial queda fuera del esquema y del estado.

Cada cuenta guarda la autorización del usuario: proveedor, origen HTTP o carpeta,
cabeceras permitidas y definición de credencial. El transporte compara la
petición con la autorización vigente y añade la credencial en Rust. El código
no puede enviarla a otro origen ni seguir redirecciones para extraerla. Cambiar
la declaración del proyecto no amplía una cuenta ya autorizada. Una receta usa
`api.cuenta(id).fetch` como transporte de un SDK que permita sustituir `fetch`.
Así puede consultar y modificar Notion con su cuenta sin ver el token. Las
operaciones de cuenta no crean por sí mismas una publicación gestionada. Sólo
`publicar` y el recibo del conector participan en la regeneración y retirada
posteriores.

El [proyecto externo de ejemplo](../examples/conectores/README.md) muestra el
manifiesto, un formulario con opciones dinámicas, clave de API, publicación con
recibo y receta que consulta y escribe mediante `cuenta.fetch`. Se construye con
las herramientas del proyecto y puede distribuirse sólo como `dist/`, sin
fuentes ni dependencias instaladas en el Mac de destino.

Una escritura arbitraria iniciada por una receta puede terminar sin respuesta
confirmada. Escriba no la repite automáticamente; queda pendiente hasta que el
usuario decide cómo continuar y reprocesa manualmente. Las publicaciones gestionadas siguen
la reconciliación y los recibos definidos por cada conector. OAuth, SDK sin
transporte intercambiable y recuperación automática de efectos arbitrarios
siguen fuera de alcance.

## Alcance de la extensión

- Declaraciones de proveedores, configuración y formularios aportadas por el
  proyecto, incluidas las opciones que se obtengan del servicio con su cuenta.
- Captura y conservación de credenciales a cargo de Escriba, separadas de los
  valores ordinarios de los formularios. El proyecto declara lo necesario;
  nunca recibe la credencial guardada.
- Transporte autenticado utilizable por SDK desde recetas y conectores, sujeto
  a la cuenta y autorización vigentes. La semántica del proveedor reside en el
  proyecto o sus dependencias, sin añadir casos por proveedor al host.
- Compatibilidad con las cuentas, destinos y publicaciones existentes de
  Notion y OKF, sin perder identidades, credenciales ni recibos.
- Construcción y distribución mediante el mismo `dist/`, también desde fuera
  de Escriba. El artefacto no incluye credenciales del usuario.

Libertad de operaciones no significa entregar el token al SDK ni quitar el
sandbox. El acceso sigue limitado por la cuenta autorizada y los permisos del
servicio. Un SDK debe poder utilizar el transporte del host; no se promete
compatibilidad universal con SDK que exijan red directa, binarios nativos o
recursos excluidos por el contrato actual de empaquetado.

El contrato concreto está descrito en [Proyectos de recetas](proyecto-recetas-tauri.md)
y en el README de `@escriba/conectores`. La validación instalada y las llamadas
reales autorizadas siguen los criterios de aceptación siguientes.

## Criterios de aceptación

1. **Proveedor nuevo:** un proyecto externo declara un proveedor de prueba y
   sus formularios; el usuario configura su cuenta desde Escriba y utiliza el
   conector desde una receta. Su implementación vive en ese proyecto y puede
   probarse contra un servicio local sintético. Ningún cambio en el código de
   Escriba es específico del proveedor elegido para la prueba.
2. **SDK desde una receta:** usando una cuenta Notion ya conectada, una receta
   utiliza el SDK para una consulta y una modificación con contenido sintético,
   sin pasar por `publicar(nota)` ni conocer el token real.
3. **Formularios y credenciales:** la configuración aparece desde el esquema
   del proyecto; la credencial se solicita y guarda por separado. Un dato
   inválido muestra el campo afectado y los errores del servicio son visibles.
4. **Autorización:** revocar una cuenta o cambiar su alcance surte efecto en
   las siguientes llamadas, también de programas previamente cargados. Cambiar
   el dominio solicitado por el proyecto no redirige una credencial existente.
   Las pruebas verifican que ni peticiones a otro origen ni redirecciones
   permiten extraer el secreto.
5. **Distribución y compatibilidad:** cargar sólo el `dist/` construido fuera
   de la app permite usar la integración; las cuentas y publicaciones anteriores
   siguen funcionando. La ausencia del proyecto no destruye sus recibos.
6. **Entrega:** pruebas con procesos reales, transporte local y datos sintéticos;
   release instalada para que Rubén compruebe ambos recorridos. Las llamadas a
   servicios reales requieren el encargo correspondiente y cuentas de pruebas;
   nunca se publican notas reales en Notion.

## Verificación de la implementación

- App: 219 pruebas TypeScript; comprobación de tipos del frontend y del host.
- Librería de conectores: 42 pruebas, incluidos formularios, opciones dinámicas,
  errores de campos y publicaciones conservadas.
- Rust: 214 pruebas completas y 5 ignoradas; 24 comprobaciones focalizadas tras
  los últimos cambios de actualización de proyectos y normalización de carpetas.
  Clippy con advertencias como errores y formato correctos.
- Bun compilado bajo sandbox: proveedor externo construido en un temporal,
  ejecución desde `dist/` tras retirar las fuentes, formulario, acción y recibo
  de publicación. SDK oficial de Notion con lectura y escritura sintéticas.
- Copia íntegra del ejemplo fuera del checkout: instalación de dependencias,
  comprobación con TypeScript 7 nativo y construcción usando herramientas
  incluidas bajo sandbox. No necesita rutas al repositorio para instalar paquetes.
- Interfaz revisada en navegador a 960×640 y 1260×820 con formularios Notion/OKF.
  Queda la confirmación manual de Rubén sobre la release instalada; no se han
  realizado llamadas a Notion real.
