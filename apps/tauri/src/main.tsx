import React from "react";
import { createRoot } from "react-dom/client";
import { MainWindow } from "./app/MainWindow";
import { PlatformContext } from "./app/platform";
import { platformFromQuery } from "./core/platform";
import { RecordingPanel } from "./recording/RecordingPanel";
import "./mac/mac.css";

const root = document.getElementById("root");
if (!root) throw new Error("Falta el contenedor principal de Escriba.");
const panel = new URLSearchParams(window.location.search).get("panel");
const recordingPanel = (
  <PlatformContext.Provider value={platformFromQuery(window.location.search)}>
    <RecordingPanel />
  </PlatformContext.Provider>
);
createRoot(root).render(<React.StrictMode>{panel === "recording" ? recordingPanel : <MainWindow />}</React.StrictMode>);
