# Mapas de conocimiento

Encargo de Rubén del 2026-10-11: visualizar la estructura de las ontologías y
explorar sus datos, aprovechando GraphMarks, con el estilo macOS de Escriba.
Amplía el alcance del ADR-0006 para incorporar el visor; no cambia la propiedad
de las ontologías ni los permisos de las recetas.

## Recorrido

En Recetas → Ontologías se abre un espacio completo con vuelta a Recetas.
Las vistas Estructura, Datos e Instalación conservan la gestión existente de
ontologías y separan tipos de entidades de registros concretos.

- Estructura presenta entidades y relaciones de todas las ontologías instaladas
  o de una elegida. La extensión conserva visibles sus referencias a la base.
  El inspector muestra campos declarados, tipos, obligatoriedad, origen y
  destino de relaciones. Los identificadores se cualifican por ontología.
- Datos permite elegir ontología y colección, con registros paginados. Elegir
  un registro centra el mapa en él y carga una página de sus conexiones.
  Seleccionar un nodo o una relación abre sus propiedades en el inspector.
  «Ver conexiones» y «Más conexiones» amplían el mapa; «Centrar aquí» inicia
  otro recorrido y «Reiniciar mapa» regresa a la colección elegida.
- Las relaciones tienen dirección, nombre e identidad. Se distinguen las
  relaciones paralelas, inversas, ciclos y bucles. Las referencias a la base
  y los vínculos con versiones de notas tienen estilos diferenciados. Una
  referencia cuyo destino falta se muestra sin recrear ese registro.
- Zoom, desplazamiento, arrastre de nodos y encuadre permiten leer el mapa;
  teclado y listas alternativas permiten seleccionar entidades y relaciones.
  La vista sigue el tema de macOS y cabe en la ventana mínima de 960×640.
- El trazado reserva el tamaño de tarjetas y etiquetas y rodea las tarjetas
  con conexiones ortogonales. Al arrastrar horizontalmente se sugiere otro
  orden dentro de las capas; se recalculan las rutas para conservar espacio.
  El encuadre incluye etiquetas y bucles y se adapta al abrir el inspector.
  En ventanas estrechas, el inspector ocupa una franja inferior. Los cruces
  entre conexiones siguen siendo posibles en grafos no planares.
- La visualización es de lectura. Las escrituras siguen en Biblioteca, Personas
  y los formularios existentes; no se ejecutan recetas ni publicaciones al
  recorrer un mapa.

## Alcance de los datos

Se visualizan las colecciones y relaciones declaradas en las ontologías, los
campos `reference` y los vínculos de procedencia mantenidos por Escriba. Una
tabla raw no declarada, referencias arbitrarias dentro de JSON y relaciones
calculadas por una consulta no se descubren automáticamente. La vista de
estructura describe el manifiesto instalado, no es una inspección universal
del esquema SurrealQL.

Rust conserva la propiedad de las consultas y sincroniza la base mediante el
journal existente. Los identificadores de registro se normalizan con tipos
nativos, sin comparar representaciones textuales alternativas. Las consultas
usan páginas limitadas en la base de datos; no se carga la biblioteca entera.
Las propiedades sólo se piden para la selección; cualquier vista previa
recortada se identifica. No cruzan credenciales, rutas de audio ni huellas.

La interfaz admite como máximo 160 nodos y 240 conexiones en un recorrido.
Si otra página excede ese límite, se conserva el mapa y se indica que hay que
centrarse en una entidad. Una respuesta obsoleta al cambiar de colección,
página o recorrido no sustituye la selección actual. Los errores se muestran
y no se confunden con colecciones vacías.

## Comprobación

Se prueban las consultas de grafo por el interfaz público `Knowledge` y el
despacho del host con RocksDB real y datos sintéticos: dirección, relaciones
paralelas y bucles, referencias en ambos sentidos, destinos ausentes,
procedencia, paginación y rechazo de tablas privadas. En TypeScript se prueban
las proyecciones de estructura, identidades, fusión acotada y geometría.
Se revisan las dos vistas y el inspector en navegador con datos sintéticos,
incluido tamaño mínimo y tema oscuro. Se construye e instala la release;
la validación final en pantalla corresponde a Rubén.

Comprobado el 2026-10-11: 268 pruebas activas de Rust (5 sondas locales
ignoradas), Clippy sin avisos, formato Rust, tipos de TypeScript y 165 pruebas
del núcleo de interfaz. La suite TypeScript completa tuvo un timeout en una
prueba anterior de empaquetado del SDK mientras corría Rust; ese archivo pasó
sus 10 pruebas al repetirlo por separado con su timeout original.
La revisión visual con datos sintéticos cubre estructura, registros,
propiedades de relaciones, cambio de selección, referencias a personas,
procedencia, bucles, relaciones paralelas, ventana de 960×640 y tema oscuro.

Corrección posterior a la captura de Rubén: ELK Layered sustituye la colocación
manual que dejaba etiquetas y conexiones sobre otras tarjetas. El caso de
regresión reproduce las nueve entidades de la captura; también se prueban
ciclos, relaciones paralelas, bucles y encuadre de mapas grandes. El cálculo
usa un worker local empaquetado en la app y no consulta servicios externos.
Pasaron las 166 pruebas del núcleo y la compilación de producción. En navegador
se comprobó ese paquete con la CSP de la app, incluido un fallo HTTP simulado
al cargar el worker: se muestra el error y «Reintentar» recupera el mapa.
