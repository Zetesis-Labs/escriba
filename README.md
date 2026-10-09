# Escriba

<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Escriba"></p>

Biblioteca de notas de voz para macOS 26: graba o importa audio, transcribe con
WhisperKit, resume con Apple Intelligence y publica mediante recetas y conectores
TypeScript. También admite resolutores compatibles con OpenAI y carpetas vigiladas
de Just Press Record, Notas de Voz o cualquier colección de audio.

La aplicación de escritorio utiliza **Tauri, TypeScript y Rust**, con
**SurrealDB embebida** para datos y trabajos duraderos. Swift adapta las APIs
nativas de Apple. La implementación SwiftUI se conserva durante la transición.

## Empezar

```sh
./scripts/build-tauri.sh --release
./scripts/install-tauri.sh --release
```

Se instala como **Escriba Tauri.app**. Al abrirla con la biblioteca vacía incorpora
las grabaciones de Escriba sin modificar el origen ni leer sus credenciales.
En Ajustes también se puede importar otra biblioteca. La app mantiene los trabajos
al cerrar la ventana y recupera el procesamiento interrumpido tras reiniciar.

- [Aplicación, requisitos, funciones y validación](apps/tauri/README.md)
- [Persistencia SurrealDB e importación](docs/tauri-persistence.md)
- [Runtime TypeScript aislado y paquetes npm](apps/tauri/runtime-host/README.md)
- [Protocolo del adaptador Apple](docs/tauri-native-protocol.md)
- [Decisión de migración](docs/adr/0003-migracion-tauri-surrealdb.md)
- [CLI y referencia de los targets Swift anteriores](docs/legacy-swiftui.md)

Los conectores Notion y OKF viven en `packages/conectores`, compartidos por ambas
aplicaciones. Las recetas se editan en una carpeta elegida por el usuario y se
compilan con esbuild. Los secretos y el audio se manejan mediante capacidades
nativas; las recetas no reciben los tokens.

## Desarrollo

```sh
./scripts/build-tauri.sh --dev
npm test --prefix apps/tauri
cargo test --manifest-path apps/tauri/src-tauri/Cargo.toml --lib
```

El repositorio conserva las suites Swift, Linux y WASI del núcleo anterior.
La aplicación macOS se compila con el SDK de Apple, fuera del devcontainer de
otros proyectos. Las instrucciones completas están en [CLAUDE.md](CLAUDE.md).

Licencia MIT.
