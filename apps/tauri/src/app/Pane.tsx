import type { ReactNode } from "react";
import { drawsWindowControls } from "../core/platform";
import { usePlatform } from "./platform";
import { WindowControls } from "./WindowControls";

export function Pane({ title, toolbar, children }: { title: string; toolbar?: ReactNode; children: ReactNode }) {
  const platform = usePlatform();
  return (
    <div className="pane">
      <header className="pane-toolbar" data-tauri-drag-region>
        <h1 className="pane-title" data-tauri-drag-region>
          {title}
        </h1>
        <div className="pane-toolbar-items">{toolbar}</div>
        {drawsWindowControls(platform) && <WindowControls />}
      </header>
      <div className="pane-body">{children}</div>
    </div>
  );
}
