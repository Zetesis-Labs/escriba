# Proveedores y SDK desde el proyecto de recetas

Objetivo confirmado por Rubén el 2026-10-11. Ampliación del proyecto TypeScript
aprobado y del [ADR-0001](adr/0001-conectores-en-typescript.md).
**Pendiente de implementación y validación instalada.** Este documento describe
el comportamiento requerido, no una capacidad disponible en la versión actual.

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

## Qué se conserva y qué falta

Ya existen proyectos con dependencias npm, construcción de `dist/`, formularios
de recetas con Zod, programas de conectores en TypeScript, almacenamiento privado
de credenciales y transporte autenticado en Rust.

Falta generalizar la declaración, configuración y autorización de proveedores.
La pantalla y los tipos actuales de cuentas y destinos contemplan Notion y OKF;
la política HTTP del runtime contiene condiciones específicas de Notion. La
receta sólo recibe `conector(...).publicar(nota)`, mientras que el transporte
autenticado se entrega únicamente al programa del conector.

Referencias de la revisión:

- `apps/tauri/src/connectors/ConnectorsPane.tsx` y `ConnectorEditor.tsx`:
  proveedores y editores fijados en la aplicación.
- `apps/tauri/src/types.ts`: cuentas y destinos con dos proveedores posibles.
- `apps/tauri/src/runtime/worker.ts`: interfaz de receta y transporte del conector.
- `apps/tauri/src/runtime/connectors.ts` y
  `apps/tauri/src-tauri/src/capabilities.rs`: autorización, transporte y
  restricciones específicas del proveedor.

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

La forma exacta de la interfaz TypeScript, las declaraciones de autenticación y
el modelo de permisos se concretarán al implementar. Este objetivo no da por
resueltos OAuth, SDK con transporte no sustituible ni la recuperación automática
de efectos arbitrarios ante un reintento. El diseño debe hacer explícito qué
acciones se pueden repetir y evitar repetir a ciegas escrituras inciertas.

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
