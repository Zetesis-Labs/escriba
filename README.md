# Escriba

<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Escriba"></p>

Biblioteca de notas de voz para macOS 26: graba o importa audio, transcribe con
WhisperKit, resume con Apple Intelligence y publica mediante recetas y conectores
TypeScript. También admite resolutores compatibles con OpenAI y carpetas vigiladas
de Just Press Record, Notas de Voz o cualquier colección de audio.

La aplicación de escritorio utiliza **Tauri, TypeScript y Rust**, con
**SurrealDB embebida** para datos y trabajos duraderos. Swift adapta las APIs
nativas de Apple. Se distribuye una sola aplicación: **Escriba.app**.

## Empezar

```sh
./scripts/build-app.sh --release
./scripts/install-app.sh --release
```

Se instala como **Escriba.app**. La biblioteca y la configuración existentes se
conservan al actualizar. La app mantiene los trabajos
al cerrar la ventana y recupera el procesamiento interrumpido tras reiniciar.

- [Aplicación, requisitos, funciones y validación](apps/tauri/README.md)
- [Persistencia SurrealDB](docs/tauri-persistence.md)
- [Runtime TypeScript aislado y paquetes npm](apps/tauri/runtime-host/README.md)
- [Protocolo del adaptador Apple](docs/tauri-native-protocol.md)
- [Decisión de migración](docs/adr/0003-migracion-tauri-surrealdb.md)
- [Identidad única de la aplicación](docs/adr/0005-escriba-unica-app.md)

Los conectores Notion y OKF viven en `packages/conectores`. Las recetas se editan en una carpeta elegida por el usuario y se
construyen con el Bun incluido en Escriba. El playground CodeMirror incorpora
instalación de dependencias, comprobación de tipos con TypeScript 7 y pruebas;
la app carga el `dist/` resultante. Véase [proyectos de recetas](docs/proyecto-recetas-tauri.md).
Los secretos y el audio se manejan mediante capacidades
nativas; las recetas no reciben los tokens.

## Desarrollo

```sh
./scripts/build-app.sh --dev
npm test --prefix apps/tauri
cargo test --manifest-path apps/tauri/src-tauri/Cargo.toml --lib
```

El adaptador nativo y el CLI mantienen sus suites Swift, Linux y WASI.
La aplicación macOS se compila con el SDK de Apple, fuera del devcontainer de
otros proyectos. Las instrucciones completas están en [CLAUDE.md](CLAUDE.md).

Licencia MIT.
