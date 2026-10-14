export type System = "macos" | "linux";

export interface Platform {
  system: System;
  recipesIsolated: boolean;
}

export const macOS: Platform = { system: "macos", recipesIsolated: true };

export const platformOf = (data: { platform?: Platform } | null | undefined): Platform => data?.platform ?? macOS;

const isLinux = (platform: Platform) => platform.system === "linux";

export const device = (platform: Platform) => (isLinux(platform) ? "equipo" : "Mac");
export const offersVoiceMemos = (platform: Platform) => !isLinux(platform);
export const offersFolderAuthorization = (platform: Platform) => !isLinux(platform);
export const offersSystemSettings = (platform: Platform) => !isLinux(platform);

export const revealInFolder = (platform: Platform) => (isLinux(platform) ? "Mostrar en la carpeta" : "Mostrar en Finder");
export const openInFolder = (platform: Platform) => (isLinux(platform) ? "Mostrar en la carpeta" : "Abrir en el Finder");
export const revealShort = (platform: Platform) => (isLinux(platform) ? "Carpeta" : "Finder");
export const shortcut = (platform: Platform, key: string) => (isLinux(platform) ? `Ctrl+${key}` : `⌘${key}`);

export const foldersFooter = (platform: Platform) =>
  isLinux(platform)
    ? "Cualquier audio que caiga en ellas lo procesa la receta por defecto, que se configura en Recetas."
    : "Cualquier audio que caiga en ellas lo procesa la receta por defecto, que se configura en Recetas. Si macOS impide leer una carpeta, puedes autorizarla; si aun así no deja leerla, la alternativa es el acceso total al disco.";

export const unisolatedRecipesWarning = (platform: Platform) =>
  platform.recipesIsolated
    ? null
    : "Este equipo no permite aislar las recetas: su código se ejecuta con tus permisos y podría leer tus archivos o conectarse a internet.";

export const drawsWindowControls = (platform: Platform) => isLinux(platform);

type Keys = { key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean; shiftKey: boolean };

// macOS gets ⌘N from its menu bar; Linux has no menu bar inside the window.
export const isNewRecordingShortcut = (event: Keys, platform: Platform) =>
  isLinux(platform) && event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "n";

// The recording panel is its own webview without library data: Rust names the system in its URL.
export const platformFromQuery = (search: string): Platform =>
  new URLSearchParams(search).get("platform") === "linux" ? { system: "linux", recipesIsolated: false } : macOS;

// macOS draws the panel with Liquid Glass; elsewhere the window is plainly transparent.
export const paintsPanelBackground = (platform: Platform) => isLinux(platform);

// Wayland lets no app place or raise its own windows, so Linux docks the panel inside the window.
export const floatingRecordingPanel = (platform: Platform) => !isLinux(platform);
