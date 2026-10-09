import { startsNewSpeaker, type PlaybackPosition } from "../core/presentation";
import type { Transcript } from "../types";

const clicked = () => !window.getSelection() || window.getSelection()!.isCollapsed;

export function Karaoke({ transcript, position, onSeek }: { transcript: Transcript; position: PlaybackPosition | null; onSeek: (time: number) => void }) {
  if (!transcript.segments.length) return <p className="karaoke-plain selectable">{transcript.text}</p>;
  return (
    <div className="karaoke selectable">
      {transcript.segments.map((segment, index) => {
        const current = position?.segment === index;
        return (
          <div className="turn" key={`${segment.start}-${index}`}>
            {segment.speaker && startsNewSpeaker(transcript.segments, index) && <div className="turn-speaker font-caption">{segment.speaker}</div>}
            {current && segment.words?.length ? (
              <p className="turn-words">
                {segment.words.map((word, wordIndex) => (
                  <span
                    key={`${word.start}-${wordIndex}`}
                    className={`word ${position?.word === wordIndex ? "current" : ""}`}
                    onClick={() => clicked() && onSeek(word.start)}
                  >
                    {word.text.trim()}
                  </span>
                ))}
              </p>
            ) : (
              <p className={`turn-text ${current ? "current" : ""}`} onClick={() => clicked() && onSeek(segment.start)}>
                {segment.text}
              </p>
            )}
          </div>
        );
      })}
    </div>
  );
}
