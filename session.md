# Relevo: Escriba en Linux

Estado al 2026-10-14 para el agente que continúa. Léelo entero antes de tocar
nada.

## Qué es y cómo se trabaja

Escriba es una app de notas de voz (Tauri: React/TypeScript + Rust + controlador
Bun) que se está llevando de macOS a Linux. El trabajo va en la rama
**`feat/linux`**, 56 commits por delante de `origin/main` (al día con `main`, sin
push). Copia anterior al último rebase: rama `feat/linux-pre-rebase`.

Documentos que mandan, en este orden:

1. `docs/plan-linux.md`: fases L0–L7, decisiones cerradas, entorno y, al
   final, el **Registro** con lo hecho por fase y lo que debe comprobar la sesión
   del Mac. Actualízalo al cerrar cada fase.
2. `docs/adr/0010-linux-host-nativo-en-rust.md` y
   `docs/adr/0011-dominio-en-bun-rust-cascara.md`.
3. `specs/escriba/linux/functional-specs.md` y
   `specs/escriba/modelos-whisper/functional-specs.md`.
4. `CLAUDE.md` (todo menos el bloque «Construir y comprobar», que es de macOS).
5. `docs/tauri-native-protocol.md` (protocolo del host nativo).

Reglas de Rubén, el dueño:

- Una fase está hecha cuando él la ve funcionar en su Ubuntu, no cuando pasan
  los tests. Al acabar, instala y avisa.
- Tests primero en cada vertical. Nada fuera de la spec sin preguntar. Las
  «Decisiones cerradas» del plan no se reabren.
- Respuestas cortas, una pregunta cada vez, en castellano.
- Commits convencionales en castellano, uno por cosa, **sin trailers de IA**,
  con autor `Rubén García <ruben@nexolabs.xyz>` (no hay `git config` en la
  máquina: usa `git -c user.name=… -c user.email=… commit`). Sin push, merge ni
  PR salvo que lo pida. Actualizar la rama: rebase sobre `main`, nunca merge.
- No cambiar el comportamiento de macOS. Lo que difiere por sistema va tras su
  puerto: `native-host/src/platform/<sistema>/`, `platform::PLATFORM` en Rust
  (llega a la interfaz y al controlador) o un módulo por sistema. Lo que pueda
  afectar al Mac se apunta en `docs/pendiente-mac.md`.

## Entorno de esta máquina (Ubuntu 25.10 x86_64, Wayland)

- Herramientas en el usuario, no en el PATH por defecto:
  `export PATH=~/.cargo/bin:~/.bun/bin:~/.local/opt/node/bin:$PATH`
  (Rust 1.99, Bun 1.4.2, Node 22).
- Construir todo: `./scripts/build-linux.sh` (debug) o `--release` (deja
  `apps/tauri/src-tauri/target/release/bundle/deb/Escriba_0.1.0_amd64.deb`).
  También prepara `vendor/`, el binding de SurrealDB, el runtime y el host
  nativo que necesitan las pruebas.
- Instalar: Rubén tiene que cerrar Escriba **desde la bandeja → «Salir»**
  (cerrar la ventana solo la oculta). Luego
  `pkexec apt-get install -y --reinstall <deb>`: le sale una ventana para la
  contraseña. Comprueba con `ls -la /usr/bin/escriba-tauri` que la hora cambió.
- No hay capturas desde la sesión (Wayland). Rubén puede dejarlas en
  `~/Imágenes/Capturas de pantalla`.
- **Memoria:** `/tmp` es tmpfs. La suite de Rust ya no tiene fugas, pero lanza
  las tandas largas con límite:
  `systemd-run --user --scope -q -p MemoryMax=12G -p MemorySwapMax=0 cargo test --lib`.
  Una vez el OOM tumbó el escritorio.
- Hay un modelo real de 1,6 GB en `~/.local/share/escriba/models`
  (large-v3-turbo); las pruebas del host usan siempre carpetas temporales.

Comprobaciones antes de entregar:

```bash
cd apps/tauri/src-tauri && cargo check --all-targets && cargo test --lib \
  && cargo clippy --all-targets -- -D warnings && cargo fmt --check
cd ../native-host && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check
cd .. && npm test && npx tsc --noEmit && npm run typecheck:runtime
```

`tests/runtime/worker.test.ts` («tiempo de inferencia en host…») a veces falla
con el equipo cargado y pasa al repetir.

## Estado por fase

| Fase | Estado |
|---|---|
| L0 diagnóstico | hecha |
| L1 compila y pasa tests | hecha |
| L2 arranca y procesa con STT remoto | hecha, validada por Rubén |
| L3 grabar | hecha, validada por Rubén |
| L4 Whisper local | hecha, validada por Rubén |
| Varios modelos de Whisper | validado en Linux; falta Swift |
| Puertos por sistema | hecho (sin cambios visibles) |
| L5 hablantes y Personas | **siguiente** |
| L6 aislar recetas | pendiente, diseño propuesto abajo |
| L7 paquetes y CI | pendiente |

Piezas clave ya hechas:

- `apps/tauri/native-host/`: host nativo de Linux en Rust (protocolo v1).
  `status`, `audioInfo`, `fileStatus`, `materialize`, grabación Opus/Ogg con
  cpal (`recording/`), whisper.cpp (`whisper.rs`), `models`, `deleteModel`.
  Lo propio de Linux en `src/platform/linux/` (ver Registro, «puertos»).
  Batería común en `tests/contract.rs` y la de Linux en `tests/linux.rs`
  (`ESCRIBA_AUDIO_SOURCE` inyecta audio, `ESCRIBA_MODELS_URL` un servidor de
  modelos). Pruebas reales con `--ignored`.
- Rust de la app: `src-tauri/src/platform.rs` (decisiones por sistema),
  `folder_access_linux.rs`, `tray_icons.rs`, notificaciones con `notify-rust`.
- Controlador Bun: `src/runtime/platform.ts` (valores de serie por sistema),
  `src/runtime/localModels.ts` (un resolutor local por modelo).
- Interfaz: `src/core/platform.ts` + `src/app/platform.ts` (`PlatformContext`)
  con lo que Rust dice en `platform::PLATFORM` (tipo generado),
  cabecera estilo GNOME (`WindowControls.tsx`), panel de grabación dentro de la
  ventana en Linux.

Decisiones de Rubén tomadas en esta sesión (además de las del plan):

- Ventana sin barra del sistema, con cabecera estilo GNOME y botones a la
  derecha; sin barra de menús en Linux; Ctrl+N graba.
- Sin panel flotante en Linux (Wayland no deja colocarlo): va dentro de la
  ventana, centrado arriba.
- Varios modelos de Whisper, opción A: cada modelo añadido es un resolutor local
  `local-stt-<modelo>`; el de serie (`local-stt`) sigue tomando el modelo de los
  ajustes. Spec en `specs/escriba/modelos-whisper/`.
- La parte de Swift (Mac) se hará al terminar Linux.

## Pendiente

### Preguntas abiertas para Rubén

- Botón de pausa en el panel: solo Linux, en los dos sistemas o ninguno (el host
  de Linux ya pausa).
- Impedir la suspensión del equipo mientras graba (el Mac lo hace).
- Ctrl+Q para salir en Linux.
- Gráfica para Whisper (hoy procesador; el plan pide demostrar que es estable).

### L5. Hablantes y Personas (siguiente)

Ver el plan. Resumen: diarización y huellas en el host de Rust con un motor que
funcione en Linux (candidato: sherpa-onnx), modelos descargados explícitamente.
Hoy `transcribe` con `diarize: true` y `diarizedVoices` fallan avisando. Contrato
de `transcribe` con `diarize`/`speakers` y de `diarizedVoices` con audio de dos
voces de `espeak-ng` (por ejemplo `-v es` y `-v es+f3`). Calibrar el umbral (el
0,30 del `CLAUDE.md` es de SpeakerKit) y apuntar el valor en el plan. Las huellas
no salen del host ni del controlador. Hecho cuando Rubén registra una voz de 30 s
y una grabación nueva la reconoce.

### L6. Aislar recetas: diseño propuesto a Rubén (no implementado)

Rust aplica al lanzar cada worker de receta (`scripts.rs`, `spawn` con
`worker = true`; hoy en Linux arranca sin aislar porque
`platform::recipes_isolated()` es falso):

1. `prctl(PR_SET_NO_NEW_PRIVS)`.
2. Landlock: solo lectura del ejecutable y sus bibliotecas; sin escritura; red
   TCP prohibida (ABI 4, kernel ≥ 6.7).
3. seccomp: sin `execve`/`fork` (sí hilos; `clone3` → ENOSYS) ni sockets
   nuevos de red o Unix, salvo el canal heredado.

Sin bubblewrap: Ubuntu 24.04 restringe los espacios de nombres sin privilegios
con AppArmor. Detección en arranque; si no se puede, decisión 3 (sin aislar con
aviso). Pruebas: las tres de aislamiento de `tests/runtime/sidecar.test.ts` (hoy
`isolation`, solo macOS) y las equivalentes de `scripts.rs`/`project.rs`, en
Ubuntu 24.04 y Fedora. Riesgo: Bun/JavaScriptCore necesita llamadas de sistema
poco comunes; ajustar seccomp con recetas reales. Las herramientas del proyecto
(`project.rs`) conservan su permiso de red al instalar.

### L7. Paquetes y CI

`.rpm`, arm64, dependencias declaradas (WebKitGTK 4.1, AppIndicator, ALSA,
GStreamer), jobs de CI en `ubuntu-24.04` y `ubuntu-24.04-arm`, comprobar m4a en
una instalación limpia y rellenar la matriz del Registro.

### Sesión del Mac (al terminar Linux)

Todo en `docs/pendiente-mac.md`, por orden: varios modelos de Whisper en Swift,
lo que Swift no cumple del protocolo, grabar y archivos con el host de Rust,
compilar lo movido y comprobar en pantalla.
