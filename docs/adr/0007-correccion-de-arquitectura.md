# Corrección de arquitectura de octubre de 2026

Aceptado por Rubén el 2026-10-11 y ejecutado el 2026-10-12. El plan completo,
con sus fases, desviaciones y estado, está en
`docs/plan-correccion-arquitectura.md`.

La revisión encontró que la biblioteca reescribía filas que no cambiaban, que
los trabajos de red esperaban a la inferencia, que el grafo se reproyectaba
entero y que el contrato entre Rust y TypeScript se despachaba por cadenas con
cinco copias del modelo. Rubén resolvió cinco decisiones:

1. Se retira la pila de recetas en Swift y los jobs de Linux y WASI del CI.
   Ningún binario publicado la ejecutaba. Swift queda solo en macOS.
2. El CLI `escriba` se conserva tal cual, con su ledger y su biblioteca GRDB.
   Su retirada se decidirá en otro encargo.
3. La proyección de `knowledge.surrealkv` mantiene las palabras, pero dentro de
   su segmento y no como registros con arista propia. Medido el 2026-10-12 en la
   biblioteca de Rubén: 532.205 palabras y otras tantas aristas eran el 82 % de
   los registros y el grafo ocupaba 2,2 GB frente a 82 MB de biblioteca. Con las
   palabras en el segmento y referencias nativas en lugar de `has_segment` y
   `spoken_by` la base nueva ocupa 146 MB. Rubén decidió además proyectar solo
   la versión vigente: 80 MB, y `derived_from` desaparece porque su destino ya
   no está en el grafo. Las versiones anteriores se consultan en la biblioteca.
   SurrealKV no devuelve el espacio de lo borrado, así que un grafo anterior
   conserva su tamaño hasta reconstruir el fichero. La versión vigente se
   proyecta con huellas.
4. El contrato es un enum etiquetado en Rust, del que salen los tipos de
   TypeScript con ts-rs. Un método desconocido falla al deserializar.
5. Las recetas conservan el SDK oficial de SurrealDB sobre el motor RPC
   emulado. Un test fija la pareja de versiones con los crates de Rust.

Se mantienen Tauri, SurrealDB y Bun. Las bibliotecas existentes siguen
abriendo sin migración: el esquema no sube de versión porque no hay
incompatibilidad. La lista de comandos de `apps/tauri/CONTRACT.md` se queda
porque describe semántica que el tipo no expresa; un test exige que nombre
todas las variantes del enum.

Quedan fuera de esta pasada tipar los parámetros de los comandos que no son de
conocimiento y sustituir `sandbox-exec`, que Apple marca como obsoleto y no
tiene sustituto público sin App Sandbox.
