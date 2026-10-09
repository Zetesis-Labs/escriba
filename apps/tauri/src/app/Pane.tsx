import type { ReactNode } from "react";

export function Pane({ title, toolbar, children }: { title: string; toolbar?: ReactNode; children: ReactNode }) {
  return (
    <div className="pane">
      <header className="pane-toolbar" data-tauri-drag-region>
        <h1 className="pane-title" data-tauri-drag-region>
          {title}
        </h1>
        <div className="pane-toolbar-items">{toolbar}</div>
      </header>
      <div className="pane-body">{children}</div>
    </div>
  );
}
