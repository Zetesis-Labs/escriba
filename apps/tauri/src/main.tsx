import React from "react";
import { createRoot } from "react-dom/client";
import { MainWindow } from "./app/MainWindow";
import "./mac/mac.css";

const root = document.getElementById("root");
if (!root) throw new Error("Falta el contenedor principal de Escriba.");
createRoot(root).render(
  <React.StrictMode>
    <MainWindow />
  </React.StrictMode>,
);
