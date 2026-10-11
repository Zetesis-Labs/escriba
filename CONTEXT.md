# Escriba

Escriba convierte grabaciones en notas mediante recetas y permite trabajar con
ellas en servicios externos o carpetas autorizadas por el usuario.

## Lenguaje

**Grabación**: audio incorporado a la biblioteca, con su identidad y origen.
Puede conservar sus transcripciones aunque ya no exista una copia del audio.

**Nota**: resultado de procesar una grabación, con transcripción y, cuando
corresponde, resumen y datos producidos por la receta.

**Versión**: estado confirmado de una nota. Conserva su contenido para consultar
el resultado anterior de un procesamiento o una corrección.

**Borrador de versión**: conjunto de correcciones manuales de una nota que aún
no se han confirmado. Agrupa los cambios hasta guardarlos como una sola versión;
descartarlo conserva la versión de origen.

**Receta**: flujo que decide cómo procesar una grabación y qué hacer con su nota.
Sus parámetros permiten configurar ese flujo para el usuario o una ejecución.

**Proyecto de recetas**: conjunto del usuario que reúne recetas, conectores y
sus dependencias para utilizarlos en Escriba.

**Ontología**: definición instalada de un dominio de conocimiento, con identidad
estable, colecciones y una versión. Pertenece a la biblioteca y sigue disponible
aunque se cambie o retire el proyecto de recetas que la propuso.

**Ontología base**: vocabulario común de Escriba para las personas, grabaciones,
versiones, transcripciones, hablantes, segmentos y palabras de la biblioteca y
sus relaciones. Siempre está disponible y la mantiene Escriba.

**Extensión de conocimiento**: ontología adicional que aporta conceptos y
relaciones propios, y puede referenciar entidades de la ontología base.

**Referencia a la base**: identidad de una entidad existente de Escriba usada
por una extensión. Conserva su identidad aunque el origen deje de estar
disponible; no crea otra persona ni otra nota.

**Colección de conocimiento**: clase de registros de una ontología, incluida una
relación entre dos clases cuando corresponde. Su declaración describe también
los campos que Escriba puede presentar en un formulario.

**Registro de conocimiento**: entidad o relación compartida de una colección.
Puede estar vinculada a varias notas sin duplicarse.

**Vínculo de conocimiento**: asociación entre un registro de conocimiento y una
versión de nota, con la grabación y, si procede, la receta de origen.
_Evitar_: publicación, que se refiere a un destino externo.

**Filtro de Biblioteca**: criterio que selecciona notas por las entidades y
relaciones de su conocimiento. Se aplica al contenido confirmado vigente.

**Filtro guardado**: criterio visual o consulta SurrealQL con nombre que la persona conserva para volver a
seleccionar sus notas desde Biblioteca. Pertenece a la biblioteca y permanece
disponible aunque cambie el proyecto de recetas.

**Proveedor**: servicio o formato con el que se integra Escriba, como Notion
u OKF. No representa una cuenta concreta del usuario.

**Cuenta**: vínculo autorizado por el usuario con un proveedor, que conserva
sus credenciales y el alcance concedido; en un proveedor local puede ser una
carpeta sin credencial remota.
_Evitar_: destino, cuando se habla únicamente de autenticación o permisos.

**Conector**: integración que define cómo configurar y utilizar un proveedor.
Se utiliza con una cuenta autorizada y puede ofrecer destinos de publicación.

**Destino**: ubicación y reglas de representación elegidas para publicar notas
con una cuenta, como una base de Notion con su mapeo de propiedades.
_Evitar_: cuenta, cuando se habla de dónde y cómo publicar.

**Publicación**: relación duradera entre una nota y un destino, con la
información necesaria para localizar, actualizar o retirar lo publicado.

**Operación de cuenta**: consulta o cambio realizado en un proveedor usando
una cuenta autorizada. No toda operación crea una publicación de una nota.
