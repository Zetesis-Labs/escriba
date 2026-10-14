import type { Platform } from "../generated/Platform";
import type { System } from "../generated/System";
import platforms from "../generated/platforms.json";

export type { Platform, System };

// What Rust reports on macOS; the interface assumes it until the library arrives.
export const macOS = platforms.macos as Platform;

export const platformOf = (data: { platform?: Platform } | null | undefined): Platform => data?.platform ?? macOS;

const isMac = (platform: Platform) => platform.system === "macos";

export const device = (platform: Platform) => (isMac(platform) ? "Mac" : "equipo");
export const whisperName = (system: System) => (system === "macos" ? "Whisper en este Mac" : "Whisper · en este equipo");
export const offersVoiceMemos = (platform: Platform) => platform.voiceMemos;
export const offersFolderAuthorization = (platform: Platform) => platform.folderAuthorization;
export const offersSystemSettings = (platform: Platform) => platform.systemSettings;

export const revealInFolder = (platform: Platform) => (isMac(platform) ? "Mostrar en Finder" : "Mostrar en la carpeta");
export const openInFolder = (platform: Platform) => (isMac(platform) ? "Abrir en el Finder" : "Mostrar en la carpeta");
export const revealShort = (platform: Platform) => (isMac(platform) ? "Finder" : "Carpeta");
export const shortcut = (platform: Platform, key: string) => (isMac(platform) ? `⌘${key}` : `Ctrl+${key}`);

export const foldersFooter = (platform: Platform) =>
  platform.folderAuthorization
    ? "Cualquier audio que caiga en ellas lo procesa la receta por defecto, que se configura en Recetas. Si macOS impide leer una carpeta, puedes autorizarla; si aun así no deja leerla, la alternativa es el acceso total al disco."
    : "Cualquier audio que caiga en ellas lo procesa la receta por defecto, que se configura en Recetas.";

export const unisolatedRecipesWarning = (platform: Platform) =>
  platform.recipesIsolated
    ? null
    : "Este equipo no permite aislar las recetas: su código se ejecuta con tus permisos y podría leer tus archivos o conectarse a internet.";

export const drawsWindowControls = (platform: Platform) => platform.drawsWindowControls;

type Keys = { key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean; shiftKey: boolean };

// With a menu bar, ⌘N comes from the menu.
export const isNewRecordingShortcut = (event: Keys, platform: Platform) =>
  !platform.menuBar && event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "n";

// The floating panel gets Liquid Glass from macOS; docked inside the window it paints its own.
export const paintsPanelBackground = (platform: Platform) => !platform.floatingPanel;

export const floatingRecordingPanel = (platform: Platform) => platform.floatingPanel;

// Until Swift answers `models`, the Mac has no catalog and its model is WhisperKit large-v3.
export const whisperDownloadLabel = (platform: Platform) => (isMac(platform) ? "Descargar (unos 3 GB)" : "Descargar");
