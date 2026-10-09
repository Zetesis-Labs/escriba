import { memo } from "react";
import { startsNewSpeaker, type PlaybackPosition } from "../core/presentation";
import type { Segment, Transcript } from "../types";

const clicked = () => !window.getSelection() || window.getSelection()!.isCollapsed;

const Turn = memo(function Turn({
  segment,
  showsSpeaker,
  current,
  word,
  onSeek,
}: {
  segment: Segment;
  showsSpeaker: boolean;
  current: boolean;
  word: number | null;
  onSeek: (time: number) => void;
}) {
  return (
    <div className="turn">
      {showsSpeaker && segment.speaker && <div className="turn-speaker font-caption">{segment.speaker}</div>}
      {current && segment.words?.length ? (
        <p className="turn-words">
          {segment.words.map((item, index) => (
            <span key={`${item.start}-${index}`} className={`word ${word === index ? "current" : ""}`} onClick={() => clicked() && onSeek(item.start)}>
              {item.text.trim()}
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
});

export function Karaoke({ transcript, position, onSeek }: { transcript: Transcript; position: PlaybackPosition | null; onSeek: (time: number) => void }) {
  if (!transcript.segments.length) return <p className="karaoke-plain selectable">{transcript.text}</p>;
  return (
    <div className="karaoke selectable">
      {transcript.segments.map((segment, index) => (
        <Turn
          key={`${segment.start}-${index}`}
          segment={segment}
          showsSpeaker={startsNewSpeaker(transcript.segments, index)}
          current={position?.segment === index}
          word={position?.segment === index ? position.word : null}
          onSeek={onSeek}
        />
      ))}
    </div>
  );
}
