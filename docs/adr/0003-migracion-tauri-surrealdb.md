---
status: modificado por ADR-0004; reparto Rust/TypeScript corregido por ADR-0011
---

# Tauri y SurrealDB como destino de Escriba

Rubén decidió el 2026-10-09 completar la migración a Tauri y utilizar SurrealDB
definitivamente. Esta decisión sustituye el experimento del ADR-0002. La app
SwiftUI se conserva durante la transición; la nueva aplicación usa una biblioteca
propia e incorpora la anterior sin modificarla cuando arranca vacía. Esta
continuidad se corrigió el 2026-10-09 tras comprobar que exigir una importación
manual en Ajustes dejaba al usuario ante una biblioteca vacía. La incorporación
es única, visible, sin credenciales y con procesamiento automático pausado;
las bibliotecas Tauri que ya tienen grabaciones conservan la importación manual.

TypeScript implementa interfaz, recetas, conectores y transformaciones. Rust
custodia capacidades, archivos y credenciales y mantiene los trabajos en
SurrealDB embebida con SurrealKV (sustituido por RocksDB en el ADR-0008). Swift queda para WhisperKit/SpeakerKit,
FoundationModels, AVFoundation y materialización iCloud mediante APIs de Apple.

La orquestación TypeScript corre en un ejecutable Deno compilado supervisado por
Rust. Cada receta se aísla en otro proceso sin permisos y con canal propio. La
cola durable no depende de una WebView: un trabajo continúa al cerrar la ventana,
y tras terminar el proceso se recupera desde sus versiones y memoria guardadas.
Este reparto añade un ejecutable, pero elimina la dependencia entre procesamiento
y ciclo de vida de la interfaz y el runtime JavaScriptCore particular de la app.

SurrealDB almacena entidades y relaciones separadas, campos consultables e índices,
con transacciones y esquema versionado. SQLite y el documento JSON del experimento
solo se leen para importar. Los programas npm deben respetar el entorno y las
capacidades del runtime; tener Tauri no concede acceso libre a Node ni a la red.

Se pueden añadir ventanas SwiftUI especializadas si una API Apple lo requiere.
Las siete secciones actuales están en Tauri y no necesitan esas ventanas.

Corrección del 2026-10-12: el ejecutable de orquestación es Bun compilado con
`bun build --compile`, no Deno. Rust lo arranca, a él y a cada receta, bajo el
perfil de `sandbox-exec` por proceso descrito en `apps/tauri/runtime-host/README.md`.
El resto de esta decisión no cambia.

Corrección del 2026-10-13 (ADR-0011): «Rust custodia credenciales» venía de
la etapa Swift, cuando TypeScript era solo la receta. El límite del producto es
el proceso de la receta; el dominio y las credenciales se mueven al controlador
Bun y Rust queda como cáscara.
