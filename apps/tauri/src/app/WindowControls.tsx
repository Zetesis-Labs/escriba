import { getCurrentWindow } from "@tauri-apps/api/window";
import { Minus, Square, X } from "lucide-react";
import { useEffect, useState } from "react";

// Without a system title bar, the pane toolbar carries the window buttons the GNOME way.
export function WindowControls() {
  return (
    <div className="window-controls">
      <button type="button" className="window-control" aria-label="Minimizar" title="Minimizar" onClick={() => void getCurrentWindow().minimize()}>
        <Minus size={14} strokeWidth={2} />
      </button>
      <button type="button" className="window-control" aria-label="Maximizar" title="Maximizar" onClick={() => void getCurrentWindow().toggleMaximize()}>
        <Square size={11} strokeWidth={2} />
      </button>
      <button type="button" className="window-control" aria-label="Cerrar" title="Cerrar" onClick={() => void getCurrentWindow().close()}>
        <X size={14} strokeWidth={2} />
      </button>
    </div>
  );
}

export function useMaximized(enabled: boolean) {
  const [maximized, setMaximized] = useState(false);
  useEffect(() => {
    if (!enabled) return;
    const current = getCurrentWindow();
    let alive = true;
    let stop: (() => void) | undefined;
    const update = () => void current.isMaximized().then((value) => alive && setMaximized(value));
    update();
    void current.onResized(update).then((unlisten) => {
      if (alive) stop = unlisten;
      else unlisten();
    });
    return () => {
      alive = false;
      stop?.();
    };
  }, [enabled]);
  return maximized;
}
