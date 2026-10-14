import { usePlatform } from "../app/platform";
import { paintsPanelBackground } from "../core/platform";
import { Trash2 } from "lucide-react";
import { errorText } from "../mac/native";
import { discardRecording, stopRecording, useRecording } from "./useRecording";
import "./recording.css";

type DragRegion = { "data-tauri-drag-region"?: boolean };

const slots = 48;

function Waveform({ levels, drag }: { levels: number[]; drag: DragRegion }) {
  const width = 144;
  const height = 30;
  const step = width / slots;
  const bar = Math.max(step * 0.55, 1.5);
  const recent = levels.slice(-slots);
  const padded = [...Array<number>(Math.max(slots - recent.length, 0)).fill(0), ...recent];
  return (
    <svg className="waveform" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden {...drag}>
      {padded.map((level, index) => {
        const tall = Math.max(height * level, 2);
        return <rect key={index} x={index * step + (step - bar) / 2} y={(height - tall) / 2} width={bar} height={tall} rx={bar / 2} />;
      })}
    </svg>
  );
}

function RecordSymbol() {
  return (
    <svg className="record-symbol" width="22" height="22" viewBox="0 0 22 22" aria-hidden>
      <circle cx="11" cy="11" r="10.5" fill="currentColor" />
      <circle cx="11" cy="11" r="6.2" fill="none" stroke="#fff" strokeWidth="1.6" />
    </svg>
  );
}

// Docked inside the main window, dragging the panel must not move the window.
export function RecordingPanel({ docked = false }: { docked?: boolean }) {
  const recording = useRecording();
  const painted = paintsPanelBackground(usePlatform());
  const drag: DragRegion = docked ? {} : { "data-tauri-drag-region": true };
  const act = (work: () => Promise<unknown>) => () =>
    void work().catch((failure) => console.error(errorText(failure)));
  return (
    <div className={painted ? "recording-hud painted" : "recording-hud"} {...drag}>
      <RecordSymbol />
      <div className="recording-text" {...drag}>
        <span className="recording-clock" {...drag}>
          {recording.clock}
        </span>
        <span className="recording-recipe" {...drag}>
          {recording.recipeName ? `con «${recording.recipeName}»` : "Grabando"}
        </span>
      </div>
      <Waveform levels={recording.levels} drag={drag} />
      <button type="button" className="recording-discard" title="Descartar la grabación" aria-label="Descartar la grabación" onClick={act(discardRecording)}>
        <Trash2 size={16} strokeWidth={2} />
      </button>
      <button type="button" className="recording-stop" title="Detener y transcribir" aria-label="Detener y transcribir" onClick={act(stopRecording)}>
        <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
          <rect width="12" height="12" rx="2.4" fill="currentColor" />
        </svg>
      </button>
    </div>
  );
}
