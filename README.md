# Escriba

<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Escriba"></p>

<p align="center"><b>Your voice recordings, turned into notes, on your own computer.</b></p>

Escriba is a desktop app for macOS, Linux and Windows. You record a meeting or
a voice memo, or drop in any audio file. Escriba transcribes it locally, works
out who is speaking, can summarise it, and files the note where you keep your
notes: Notion, a folder of Markdown files, or any service you connect.

What happens to each recording is up to you. A **recipe**, a small TypeScript
program, decides which engine transcribes it, whether to detect speakers or
summarise, and where to publish. Escriba ships with recipes for the usual path
and shows their options as forms, so you do not need to write code to use it.

Escriba is not a dictation tool: it does not type into the app you are using.
It works on recordings, from a few seconds to a few hours, and keeps them in a
library with every version of every note.

> **The interface is in Spanish for now**, and so is the documentation under
> `docs/`. Section names below are given in Spanish with their English meaning.

## How a recording becomes a note

1. **It comes in.** You record in Escriba, import or drag in a file, or a
   folder Escriba watches gets a new one, such as the recordings Just Press
   Record or Voice Memos sync from your phone.
2. **A recipe processes it.** It transcribes, detects speakers if asked,
   summarises or answers questions you define, and decides where the note goes.
3. **The note keeps its versions.** Fix a speaker or the text, or reprocess
   with another recipe: the previous result is still there.
4. **It is published.** The note lands in Notion or a folder, and later
   corrections to its summary update it there.

## Features

- **Library** (*Biblioteca*): record (with pause), import or drag in audio, or
  watch folders: Just Press Record, Voice Memos (macOS) or any folder of audio
  files. Every note keeps its versions, so reprocessing or correcting never
  loses the previous result. Combine several recordings into one, and export
  to TXT, Markdown, SRT or JSON.
- **Local transcription**: WhisperKit on macOS (Core ML) and whisper.cpp on
  Linux and Windows. Models are downloaded explicitly from the *STT* section.
- **Speakers and people** (*Personas*): on-device speaker detection, with
  the local Whisper only. Name a
  speaker once and Escriba recognises their voice in later recordings.
  Voiceprints never leave your computer: recipes, connectors and exports do
  not receive them.
- **Summaries and structured answers**: Apple Intelligence on macOS, or any
  OpenAI-compatible endpoint, hosted or local (Ollama, LM Studio…). The same
  applies to transcription: you can add remote STT resolvers next to the local
  one. A failing remote never falls back to another engine silently.
- **Recipes** (*Recetas*): TypeScript programs that decide how a recording is
  processed and what happens to the note. Four come built in: *Transcribir*
  (transcribe), *Resumir* (summarise), *Publicar* (publish) and *Por defecto*
  (default), which chains the other three. One recipe processes everything that
  comes in; you can pick another when recording or importing.
- **Connectors** (*Conectores*): Notion, an OKF bundle (Markdown with YAML
  front matter in a folder you choose), and any provider you declare in your
  own recipe project. Correcting or removing a summary updates what was
  already published.
- **Durable jobs** (*Trabajos*): closing the window does not stop the work.
  After a restart, interrupted jobs resume without repeating transcriptions or
  answers that already finished.

Audio and text only leave your computer if you configure a remote resolver or
a connector.

## Platforms

|  | macOS | Linux | Windows |
| --- | --- | --- | --- |
| System | macOS 26, Apple Silicon | x86_64: Ubuntu 24.04 and 26.04, Debian 13, Fedora 43 and 44 | Windows 11 x64 |
| Transcription | WhisperKit | whisper.cpp | whisper.cpp |
| Speakers | SpeakerKit | sherpa-onnx | sherpa-onnx |
| Built-in LLM | Apple Intelligence | none, add an OpenAI-compatible resolver | none, add an OpenAI-compatible resolver |
| Recipe isolation | `sandbox-exec` | Landlock and seccomp | AppContainer and Job Objects |

Linux on arm64 is not available yet. The Windows build runs inference on the
CPU.

## Install

Download the package for your system from the
[latest release](https://github.com/Zetesis-Labs/escriba/releases/latest).
Each release includes SHA-256 checksums. Updating keeps your library and
settings.

### macOS

1. Download `Escriba_X.Y.Z_macos_arm64_unnotarized.zip` (up to 0.3.1 it was
   named `…_sin-notarizar.zip`), unzip it and drag `Escriba.app` to
   Applications.
2. Open it. The app is signed ad hoc, not notarised, so macOS blocks the first
   launch: go to **System Settings → Privacy & Security** and click
   **Open Anyway**. See [Apple's instructions](https://support.apple.com/en-us/102445).

Notarised builds will be named `Escriba_X.Y.Z_macos_arm64.zip` once Developer ID
signing is set up.

To watch a folder, authorise it from **Ajustes → Carpetas vigiladas**
(Settings → Watched folders). Full Disk Access is only an optional fallback.

### Linux

```sh
sudo apt install ./Escriba_X.Y.Z_amd64.deb      # Ubuntu, Debian
sudo dnf install ./Escriba-X.Y.Z-1.x86_64.rpm   # Fedora
```

The `.deb` and `.rpm` are the tested packages. The `.flatpak` is experimental:
it is not on Flathub yet and has an open redraw issue seen on a virtual
machine.

Recipe isolation needs Landlock ABI 4 or later and seccomp. If the kernel
cannot provide them, recipes run unisolated and the app shows a permanent
warning.

### Windows

Run `Escriba_X.Y.Z_x64-setup.exe`. It installs for the current user and bundles
everything it needs: no Rust, Node, Bun, Python or WSL. The installer is not
code-signed yet, so SmartScreen may warn you: choose **More info → Run anyway**.

## Getting started

1. In **STT**, download a Whisper model. Transcription never downloads models
   on its own.
2. Record, drag a file onto **Biblioteca**, or add a watched folder in
   **Ajustes**.
3. Optionally, add an LLM in **LLMs**, connect Notion or a folder in
   **Conectores**, and choose in **Recetas** which recipe processes new
   recordings.

For Notion, create an internal integration in Notion, paste its token into
Escriba and share your databases with the integration. There is no OAuth and no
Escriba server: tokens stay in private files on your computer (`0600`, or a
protected DACL on Windows) and recipes never see them.

## Recipes

A recipe project is a folder you choose in **Recetas → Cambiar…** (Change).
Edit it in the built-in CodeMirror playground or open it in VS Code or any
editor. Escriba bundles Bun and the native TypeScript 7 checker, installs npm
dependencies pinned by the lockfile, runs tests and builds `dist/`, which is
what the app loads.

A recipe declares its options with Zod and Escriba renders the form. This is
the built-in *Resumir* recipe:

```ts
import { z } from "zod"
import { camposDeResumen, notaTranscrita, resumir } from "../piezas"

export const receta = { nombre: "Resumir", parte: "nota" }

export function buildRecipeForm(listas: ListasDeEscriba) {
  return z.object(camposDeResumen(listas))
}

type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
  const nota = await notaTranscrita(audio, escriba)
  await resumir(nota, escriba.parametros)
  await nota.guardar()
}
```

Each recipe runs in its own isolated process, with no file, network or
subprocess access. It reaches the outside only through what Escriba hands it,
such as `escriba.cuenta(...).fetch` for a connected account, without seeing the
token. A recipe process is stopped above 512 MiB of memory or 10 s of active
execution (waiting on Escriba does not count), and a job is limited to two
hours.

- Built-in recipes: [`recetas/`](recetas)
- Project contract: [docs/proyecto-recetas-tauri.md](docs/proyecto-recetas-tauri.md)
- A custom provider: [examples/conectores](examples/conectores/README.md)

## Architecture

Escriba is a single [Tauri](https://tauri.app) app.

| Layer | Responsibility |
| --- | --- |
| TypeScript (Bun) | Interface, recipes, connectors, library and durable job queue on embedded SurrealDB (RocksDB) |
| Rust | App shell, permissions, files, audio capture, process supervision and recipe isolation |
| Swift (macOS) | WhisperKit, SpeakerKit, Apple Intelligence, AVFoundation capture and iCloud downloads |
| Rust native host (Linux, Windows) | whisper.cpp, sherpa-onnx and audio capture |

The window only shows state and sends actions; the work lives in separate
processes. More detail (in Spanish):
[app](apps/tauri/README.md) ·
[persistence](docs/tauri-persistence.md) ·
[recipe runtime](apps/tauri/runtime-host/README.md) ·
[native protocol](docs/tauri-native-protocol.md) ·
[Windows](docs/windows.md) ·
[Linux](docs/plan-linux.md) ·
[architecture decisions](docs/adr)

## Building from source

**macOS**: Rust stable, Node 22.12 or later, the Bun version in
`apps/tauri/runtime-host/bun-version`, and Xcode with the macOS 26 SDK.

```sh
./scripts/build-app.sh --release
./scripts/install-app.sh --release
```

**Linux** (Ubuntu 24.04): the same Rust, Node and Bun, plus

```sh
sudo apt install build-essential pkg-config clang cmake curl \
  libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
  librsvg2-dev libxdo-dev libasound2-dev espeak-ng
./scripts/build-linux.sh --release   # leaves the .deb and .rpm
```

**Windows**: Visual Studio Build Tools 2022 (C++ and Windows SDK), Rust stable,
Node 24 or later, the pinned Bun, CMake, NASM and LLVM. From PowerShell:

```powershell
./scripts/build-windows.ps1   # leaves the NSIS installer
```

**Tests**:

```sh
npm test --prefix apps/tauri
cargo test --manifest-path apps/tauri/src-tauri/Cargo.toml --lib
swift test   # native adapter and CLI, macOS only
```

Run the build script once before the first Rust test run. Contributor
guidelines are in [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
