import { Pause, Play } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { clockStamp } from "../core/presentation";

export function usePlayer(source: string | null) {
  const audio = useRef<HTMLAudioElement | null>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [isPlaying, setPlaying] = useState(false);

  useEffect(() => {
    setCurrentTime(0);
    setDuration(0);
    setPlaying(false);
    if (!source) return;
    const element = new Audio(source);
    element.preload = "metadata";
    audio.current = element;
    let frame = 0;
    const tick = () => {
      setCurrentTime(element.currentTime);
      frame = requestAnimationFrame(tick);
    };
    const metadata = () => setDuration(Number.isFinite(element.duration) ? element.duration : 0);
    const play = () => {
      setPlaying(true);
      frame = requestAnimationFrame(tick);
    };
    const stop = () => {
      setPlaying(false);
      cancelAnimationFrame(frame);
      setCurrentTime(element.currentTime);
    };
    element.addEventListener("loadedmetadata", metadata);
    element.addEventListener("play", play);
    element.addEventListener("pause", stop);
    element.addEventListener("ended", stop);
    return () => {
      cancelAnimationFrame(frame);
      element.pause();
      element.removeAttribute("src");
      element.load();
      audio.current = null;
    };
  }, [source]);

  const toggle = useCallback(() => {
    const element = audio.current;
    if (!element) return;
    if (element.paused) void element.play();
    else element.pause();
  }, []);

  const seek = useCallback((time: number, thenPlay = false) => {
    const element = audio.current;
    if (!element) return;
    element.currentTime = Math.max(0, time);
    setCurrentTime(element.currentTime);
    if (thenPlay) void element.play();
  }, []);

  return { currentTime, duration, isPlaying, toggle, seek };
}

export function PlayerBar({ player }: { player: ReturnType<typeof usePlayer> }) {
  const end = Math.max(player.duration, 0.01);
  return (
    <div className="player-bar">
      <button type="button" className="player-toggle" onClick={player.toggle} aria-label={player.isPlaying ? "Pausa" : "Reproducir"}>
        {player.isPlaying ? <Pause size={17} fill="currentColor" strokeWidth={0} /> : <Play size={17} fill="currentColor" strokeWidth={0} />}
      </button>
      <span className="secondary monospaced-digits">{clockStamp(player.currentTime)}</span>
      <input
        className="player-slider"
        type="range"
        min={0}
        max={end}
        step={0.01}
        value={Math.min(player.currentTime, end)}
        onChange={(event) => player.seek(Number(event.target.value), player.isPlaying)}
        style={{ "--progress": `${(Math.min(player.currentTime, end) / end) * 100}%` } as React.CSSProperties}
        aria-label="Posición"
      />
      <span className="secondary monospaced-digits">{clockStamp(player.duration)}</span>
    </div>
  );
}
