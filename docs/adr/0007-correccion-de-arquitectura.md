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
3. La proyección de `knowledge.surrealkv` mantiene las palabras. Su coste venía
   de reproyectar de más; ahora se proyecta por versión con huellas.
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
