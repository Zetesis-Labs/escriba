import React from "react";
import { createRoot } from "react-dom/client";
import { MainWindow } from "./app/MainWindow";
import { RecordingPanel } from "./recording/RecordingPanel";
import "./mac/mac.css";

const root = document.getElementById("root");
if (!root) throw new Error("Falta el contenedor principal de Escriba.");
const panel = new URLSearchParams(window.location.search).get("panel");
createRoot(root).render(<React.StrictMode>{panel === "recording" ? <RecordingPanel /> : <MainWindow />}</React.StrictMode>);
