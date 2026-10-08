---
status: superseded by ADR-0003
---

# Una segunda aplicación Tauri con Swift reservado a APIs nativas

Aceptado como experimento por Rubén el 2026-10-09. Escriba conserva su aplicación
SwiftUI y añade una aplicación Tauri que busca igualar sus funciones. TypeScript
se ocupa de la interfaz, las recetas, los conectores y su orquestación; Rust,
del almacenamiento y las capacidades de sistema. Swift se limita a adaptar APIs
nativas: WhisperKit/SpeakerKit, FoundationModels y AVFoundation. Esta petición
reabre expresamente la decisión anterior de descartar Tauri.

Las dos aplicaciones usan bibliotecas e identificadores distintos durante el
experimento. Se comparten las librerías TypeScript de conectores y los
adaptadores nativos; se conserva la implementación SwiftUI. El experimento no
migra automáticamente datos ni credenciales de la aplicación existente.

Pueden coexistir ventanas Tauri y ventanas SwiftUI especializadas si una API
nativa lo justifica. La primera entrega implementa las siete secciones en Tauri;
no incorpora ventanas SwiftUI al proceso auxiliar ni una segunda implementación
Swift de la lógica del producto. El propietario de cada ventana y su ciclo de
vida deberán declararse si se introduce esa integración.
