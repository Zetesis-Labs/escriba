import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState } from "react";

// Systems without a title bar of their own get macOS-style window buttons.
export function WindowControls() {
  const current = getCurrentWindow();
  return (
    <div className="window-controls">
      <button type="button" className="window-control close" aria-label="Cerrar" title="Cerrar" onClick={() => void current.close()} />
      <button type="button" className="window-control minimize" aria-label="Minimizar" title="Minimizar" onClick={() => void current.minimize()} />
      <button type="button" className="window-control maximize" aria-label="Maximizar" title="Maximizar" onClick={() => void current.toggleMaximize()} />
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
