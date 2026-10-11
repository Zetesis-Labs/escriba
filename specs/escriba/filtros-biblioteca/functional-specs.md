# Filtros de Biblioteca

Encargo de Rubén del 2026-10-11: filtros visuales sencillos por cualquier entidad
de las ontologías y consultas SurrealQL guardables. Los filtros guardados se
muestran en la barra lateral como hijos de Biblioteca. Ontologías permanece
dentro de Recetas.

## Recorrido

- Biblioteca incorpora una acción de filtros. El modo visual permite elegir
  ontología, entidad, campo, operador y valor. El catálogo se obtiene de las
  ontologías instaladas, incluida la base; no hay una lista fija de dominios.
- Se combinan condiciones cumpliendo todas o cualquiera. Los controles de valor
  respetan el tipo del campo. Las entidades sin campos propios admiten filtrar
  por identidad; las relaciones también exponen sus extremos.
  Identidades, referencias y extremos se eligen por etiquetas en páginas
  ligeras; no requieren copiar IDs ni descargar transcripciones completas.
- El modo SurrealQL permite escribir una consulta de lectura para una ontología.
  Sus resultados identifican entidades cuyas notas relacionadas se muestran en
  Biblioteca. Puede devolver IDs, registros con `id` o referencias explícitas
  a la base; se rechazan resultados que no identifican entidades.
- Una consulta SurrealQL se puede aplicar sin guardarla o guardar con un nombre.
  Los filtros guardados persisten al reiniciar y al cambiar de proyecto. Aparecen
  debajo de Biblioteca; seleccionarlos abre su lista de notas. Se pueden editar
  y eliminar. Eliminar el filtro no elimina ninguna nota.
- Quitar el filtro o seleccionar Biblioteca vuelve a la lista completa. Los
  errores no se presentan como una lista vacía ni dejan resultados anteriores
  aparentando corresponder al criterio nuevo.

## Correspondencia con notas

Se consulta la versión vigente confirmada, no el borrador ni versiones antiguas.
Las entidades de la base se corresponden con su grabación; una persona se
corresponde con las notas donde está asignada. Los registros de una extensión
usan sus vínculos explícitos con versiones y sus referencias declaradas a la
base. No se infiere una conexión con todas las notas alcanzables recorriendo
indefinidamente el grafo. Los recorridos adicionales se expresan en SurrealQL.
Un registro compartido puede producir varias notas; cada nota aparece una vez.
Todas/cualquiera combina coincidencias por nota: varias condiciones pueden
cumplirse en distintos registros de esa nota. Las fechas sin hora representan
el día UTC completo; las consultas SurrealQL permiten expresar otros intervalos.

Las bases lógicas por ontología se conservan. Las condiciones se evalúan en su
base y el host combina las identidades de grabación; la interfaz no hace joins
ni descarga transcripciones completas. La lista mantiene su proyección ligera
y sólo la nota seleccionada carga el detalle.

## Límites y comprobación

Las consultas de filtro son de lectura: no modifican esquema, entidades,
credenciales, permisos ni sesión. Los errores de sintaxis, ontología ausente,
campos inválidos y consultas excesivas se muestran de forma visible. Una
consulta obsoleta no reemplaza un filtro más reciente.
El límite de 8 MiB acota el resultado aceptado, no la memoria de ejecución del
motor: SurrealDB embebida materializa las consultas antes de entregarlas al host.
La comprobación de tamaño usa un contador sin clonar ni serializar a un buffer.

Se comprueba mediante el interfaz público Knowledge y el despacho existente,
con SurrealKV y datos sintéticos: entidades base y adicionales, tipos de campo,
relaciones, combinaciones, personas, versiones antiguas, referencias a la base,
persistencia de consultas, rechazo de escrituras incluso anidadas y aislamiento
de tablas privadas. La revisión visual cubre barra lateral, filtros activos,
errores, vacío y ventana mínima. Se instala al finalizar para validación de Rubén.

## Contrato de integración

`knowledge_filter_notes {filter}` devuelve `{recordingIds:string[]}`.

```ts
type FilterCondition = {
  ontologyId: string;
  table: string;
  field: string;
  operator: "eq" | "ne" | "contains" | "startsWith" | "gt" | "gte" | "lt" | "lte" | "empty" | "notEmpty";
  value?: unknown;
};
type LibraryFilter =
  | { kind: "visual"; match: "all" | "any"; conditions: FilterCondition[] }
  | { kind: "surrealql"; ontologyId: string; sql: string };
type SavedLibraryFilter = { id: string; name: string; ontologyId: string; sql: string };
```

`knowledge_filters_list` devuelve `SavedLibraryFilter[]`.
`knowledge_filter_save {filter:{id?,name,ontologyId,sql}}` devuelve el filtro
guardado; `knowledge_filter_remove {id}` lo elimina. Estos comandos pertenecen
a la interfaz de usuario, no a las capacidades de las recetas.
