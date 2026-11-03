import { listen } from "@tauri-apps/api/event";
import { useSyncExternalStore } from "react";
import { native } from "../api";
import { createDownloads } from "../core/downloadProgress";
import { errorText } from "../mac/native";

const downloads = createDownloads();
let listening: Promise<unknown> | null = null;

function listenOnce() {
  listening ??= listen<{ model: string; fraction: number }>("escriba://whisper-download", (event) => downloads.progress(event.payload)).catch((error) => {
    listening = null;
    throw error;
  });
  return listening;
}

export function startWhisperDownload(model: string) {
  if (!downloads.begin(model)) return;
  void listenOnce()
    .then(() => native("downloadModel", { model }))
    .then(
      () => downloads.end(model),
      (error) => downloads.end(model, errorText(error)),
    );
}

export function useWhisperDownload(model: string) {
  const fraction = useSyncExternalStore(downloads.subscribe, () => downloads.fraction(model));
  const failure = useSyncExternalStore(downloads.subscribe, () => downloads.failure(model));
  return { fraction, failure };
}
