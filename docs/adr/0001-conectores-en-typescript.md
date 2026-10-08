# Los conectores pertenecen a TypeScript

Estado: aceptado el 2026-10-08, implementado en `spike/conectores-js-npm`.

Decisión de Rubén, 2026-10-08: todos los conectores, incluidos Notion y OKF,
son responsabilidad de librerías TypeScript. Su declaración, validación,
transformaciones, protocolo, publicación, regeneración y retirada viven en
esas librerías. Se busca poder añadir operaciones y proveedores sin modificar
la aplicación Swift por cada cambio del conector.

Swift conserva capacidades genéricas: credenciales y permisos, transporte
HTTP, archivos confinados a una carpeta, ejecución de paquetes y conservación
duradera de sus recibos. La app muestra los destinos declarados por el proyecto
y administra las cuentas; las bibliotecas nunca reciben secretos.

La decisión sustituye el reparto de RF-9 que conservaba el conector en Swift.
La migración mantiene la identidad de las cuentas y los localizadores de las
publicaciones; una publicación retiene el paquete que permite actualizarla
y retirarla aunque las fuentes cambien o dejen de compilar. El comportamiento
de Notion se comprueba con un servicio falso mientras siga vigente el límite
de no llamar a la API real durante este trabajo.

La implementación retira los targets Swift `EscribaNotion` y `EscribaOKF`.
El catálogo de recetas usa un proveedor textual y metadatos comunes a cualquier
destino. Los proyectos importan dependencias npm instaladas externamente con
lockfile; Zod y los tipos del proyecto prevalecen sobre los paquetes de serie.
Los programas retienen su revisión para correcciones y retirada. La
comprobación contra Notion real y las mediciones de producción siguen siendo
validaciones independientes de esta decisión ya implementada.
