import { ChevronDown, Pencil, UserRound } from "lucide-react";
import { useLayoutEffect, useRef, useState, type CSSProperties, type TextareaHTMLAttributes } from "react";
import { clockStamp, type PlaybackPosition } from "../core/presentation";
import { groupSelectionRanges, transcriptGroups } from "../core/transcriptGroups";
import type { TranscriptSelectionRange } from "../core/transcriptEditing";
import { Button, Sheet } from "../mac/controls";
import { errorText, item, popupMenu } from "../mac/native";
import type { Person, Segment, Transcript } from "../types";

export type SpeakerTarget = { kind: "selection"; ranges: TranscriptSelectionRange[] } | { kind: "speaker"; speaker: string };

function speakerStyle(name: string | null, colors?: Readonly<Record<string, string>>): CSSProperties | undefined {
  const color = name ? colors?.[name] : undefined;
  return color && /^#[\da-fA-F]{6}$/.test(color) ? { "--speaker-color": color } as CSSProperties : undefined;
}

function gapBetween(left: string, right: string): string {
  return /\s$/u.test(left) || /^\s/u.test(right) ? "" : " ";
}

export function GrowingTextArea(props: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    const input = ref.current;
    if (!input) return;
    const resize = () => { input.style.height = "0"; input.style.height = `${input.scrollHeight + 2}px`; };
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(input.parentElement ?? input);
    return () => observer.disconnect();
  }, [props.value]);
  return <textarea {...props} ref={ref} rows={1} />;
}

export function selectedTranscriptRanges(root: HTMLElement): TranscriptSelectionRange[] {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || !selection.rangeCount) return [];
  const selected = selection.getRangeAt(0);
  const ranges: TranscriptSelectionRange[] = [];
  for (const node of root.querySelectorAll<HTMLElement>("[data-transcript-segment]")) {
    if (!selected.intersectsNode(node)) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    if (node.contains(selected.startContainer)) range.setStart(selected.startContainer, selected.startOffset);
    if (node.contains(selected.endContainer)) range.setEnd(selected.endContainer, selected.endOffset);
    const prefix = document.createRange();
    prefix.selectNodeContents(node);
    prefix.setEnd(range.startContainer, range.startOffset);
    const start = prefix.toString().length;
    const end = start + range.toString().length;
    if (start < end) ranges.push({ segment: Number(node.dataset.transcriptSegment), start, end });
  }
  return ranges;
}

function PlayingText({ segment, word }: { segment: Segment; word: number | null }) {
  const timed = word === null ? undefined : segment.words?.[word];
  if (!timed) return <>{segment.text}</>;
  let start = 0;
  for (let index = 0; index <= word!; index++) {
    const text = segment.words![index].text;
    const found = segment.text.indexOf(text, start);
    if (found < 0) return <>{segment.text}</>;
    if (index === word) return <>{segment.text.slice(0, found)}<mark>{text}</mark>{segment.text.slice(found + text.length)}</>;
    start = found + text.length;
  }
  return <>{segment.text}</>;
}

export function TranscriptEditor({ transcript, editing, disabled, position, onSeek, onText, onAssign, onError, speakerColors }: {
  transcript: Transcript; editing: boolean; disabled: boolean; position: PlaybackPosition | null;
  onSeek(time: number): void; onText(index: number, text: string): void; onAssign(target: SpeakerTarget): void; onError(message: string): void;
  speakerColors?: Readonly<Record<string, string>>;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [selection, setSelection] = useState<TranscriptSelectionRange[]>([]);
  const [editingSegment, setEditingSegment] = useState<number | null>(null);
  const assign = (ranges: TranscriptSelectionRange[]) => {
    if (!ranges.length || disabled) return;
    onAssign({ kind: "selection", ranges });
    setSelection([]);
    setEditingSegment(null);
  };
  const capture = () => root.current && setSelection(selectedTranscriptRanges(root.current));
  const selectedText = selection.map((range) => transcript.segments[range.segment]?.text.slice(range.start, range.end) ?? "").join(" ");
  const groups = transcriptGroups(transcript.segments);
  return <div className="transcript-editor" ref={root}>
    <div className="transcript-help font-caption secondary">
      <span>{editing ? "Pulsa el lápiz para corregir texto. Selecciona palabras para reasignarlas." : "Selecciona unas palabras para cambiar quién las dijo."}</span>
      {selection.length > 0 && <Button small onClick={() => assign(selection)} disabled={disabled} title={selectedText}>Asignar selección…</Button>}
    </div>
    <div className="transcript-turns selectable" onMouseUp={(event) => { if (!(event.target instanceof HTMLTextAreaElement)) capture(); }} onKeyUp={(event) => { if (!(event.target instanceof HTMLTextAreaElement)) capture(); }}>
      {groups.map((group) => {
        const first = transcript.segments[group.indices[0]];
        const playing = group.indices.includes(position?.segment ?? -1);
        return <div className={`transcript-turn ${playing ? "playing" : ""}`} style={speakerStyle(group.speaker, speakerColors)} key={group.indices[0]}>
          <div className="transcript-turn-heading">
            <button type="button" className="speaker-button" disabled={disabled} onClick={() => assign(groupSelectionRanges(group, transcript.segments))} aria-label={`Asignar hablante del bloque de ${group.indices.length} ${group.indices.length === 1 ? "intervención" : "intervenciones"}`}>
              <UserRound size={12} /><span>{group.speaker || "Sin hablante"}</span><ChevronDown size={11} />
            </button>
            <button type="button" className="turn-time font-caption monospaced-digits" onClick={() => onSeek(first.start)} title={first.timingShared ? "Tiempo de la intervención original; este fragmento no tiene tiempos precisos por palabra." : "Reproducir desde aquí"}>
              {clockStamp(first.start)}{first.timingShared ? " · aprox." : ""}
            </button>
          </div>
          <p className="transcript-turn-text" onContextMenu={(event) => {
            if (!root.current || disabled) return;
            const ranges = selectedTranscriptRanges(root.current);
            if (!ranges.length) return;
            event.preventDefault();
            setSelection(ranges);
            void popupMenu([item("Asignar hablante a la selección…", () => assign(ranges))], { x: event.clientX, y: event.clientY }).catch((error) => onError(errorText(error)));
          }}>
            {group.indices.map((index, part) => {
              const segment = transcript.segments[index];
              const previous = part > 0 ? transcript.segments[group.indices[part - 1]] : null;
              return <span className={`transcript-fragment ${position?.segment === index ? "playing" : ""}`} key={index}>
                {previous && gapBetween(previous.text, segment.text)}
                {editing && editingSegment === index ? <span className="transcript-fragment-edit"><GrowingTextArea autoFocus className="transcript-text-input selectable" aria-label={`Texto de la intervención ${index + 1}`} value={segment.text} disabled={disabled}
                  onChange={(event) => { setSelection([]); onText(index, event.target.value); }}
                  onSelect={(event) => {
                    const input = event.currentTarget;
                    setSelection(input.selectionStart === input.selectionEnd ? [] : [{ segment: index, start: input.selectionStart, end: input.selectionEnd }]);
                  }}
                  onContextMenu={(event) => {
                    const input = event.currentTarget;
                    if (input.selectionStart === input.selectionEnd) return;
                    event.preventDefault();
                    const ranges = [{ segment: index, start: input.selectionStart, end: input.selectionEnd }];
                    void popupMenu([item("Asignar hablante a la selección…", () => assign(ranges))], { x: event.clientX, y: event.clientY }).catch((error) => onError(errorText(error)));
                  }}
                /><button type="button" className="turn-edit-button" onClick={() => setEditingSegment(null)}>Listo</button></span>
                  : <span className="transcript-fragment-text" data-transcript-segment={index} onDoubleClick={() => { if (editing && !disabled) setEditingSegment(index); }}><PlayingText segment={segment} word={position?.segment === index ? position.word : null} /></span>}
                <span className="transcript-fragment-tools">
                  {editing && editingSegment !== index && <button type="button" className="turn-edit-button" aria-label={`Editar texto de la intervención ${index + 1}`} disabled={disabled} onClick={() => { setSelection([]); setEditingSegment(index); }}><Pencil size={11} /></button>}
                  {part > 0 && <button type="button" className="turn-time font-caption monospaced-digits" aria-label={`Reproducir intervención ${index + 1} desde ${clockStamp(segment.start)}`} onClick={() => onSeek(segment.start)} title={segment.timingShared ? "Tiempo de la intervención original; este fragmento no tiene tiempos precisos por palabra." : "Reproducir desde aquí"}>{clockStamp(segment.start)}{segment.timingShared ? " aprox." : ""}</button>}
                </span>
              </span>;
            })}
          </p>
        </div>;
      })}
    </div>
  </div>;
}

export function SpeakerPicker({ people, speakers, target, excerpt, onChoose, onCancel, error, speakerColors }: {
  people: Person[]; speakers: string[]; target: SpeakerTarget; excerpt: string; error: string | null;
  onChoose(name: string, personId?: string): void; onCancel(): void;
  speakerColors?: Readonly<Record<string, string>>;
}) {
  const [name, setName] = useState("");
  const saved = new Set(people.map((person) => person.name));
  const others = speakers.filter((speaker) => !saved.has(speaker));
  return <Sheet onCancel={onCancel}>
    <div className="font-title3">{target.kind === "speaker" ? `Cambiar «${target.speaker}» en toda la nota` : "Asignar hablante"}</div>
    <p className="secondary font-callout">{target.kind === "speaker" ? "Se reasignarán todas sus intervenciones en este borrador." : "Solo cambiará el fragmento seleccionado."}</p>
    {excerpt && <blockquote className="speaker-excerpt selectable">{excerpt}</blockquote>}
    <div className="speaker-choices">
      <div className="font-caption secondary">Personas guardadas</div>
      {people.length ? people.map((person) => <button type="button" className="speaker-choice" style={speakerStyle(person.name, speakerColors)} key={person.id ?? person.name} onClick={() => onChoose(person.name, person.id)}><UserRound size={15} />{person.name}</button>) : <p className="secondary font-callout">Aún no hay personas guardadas.</p>}
      {error && <p className="warning" role="alert">{error}</p>}
      {!!others.length && <><div className="font-caption secondary">Hablantes de esta nota</div>{others.map((speaker) => <button type="button" className="speaker-choice" style={speakerStyle(speaker, speakerColors)} key={speaker} onClick={() => onChoose(speaker)}><UserRound size={15} />{speaker}</button>)}</>}
    </div>
    <label className="speaker-name-label">Otro nombre<input className="text-field" value={name} placeholder="Nombre del hablante" onChange={(event) => setName(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && name.trim()) { event.preventDefault(); onChoose(name.trim()); } }} /></label>
    <div className="sheet-actions"><Button onClick={onCancel}>Cancelar</Button><Button prominent disabled={!name.trim()} onClick={() => onChoose(name.trim())}>Asignar</Button></div>
  </Sheet>;
}
