import type { Platform } from "../../src/core/platform";

// What Rust's platform::PLATFORM reports on Linux.
export const linux: Platform = {
  system: "linux",
  recipesIsolated: false,
  voiceMemos: false,
  folderAuthorization: false,
  systemSettings: false,
  bundledLlm: false,
  floatingPanel: false,
  menuBar: false,
  drawsWindowControls: true,
};
