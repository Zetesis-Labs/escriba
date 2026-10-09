import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { AudioLines, Mic, Minus, Plus, Trash2, Users, CircleDot, TriangleAlert } from "lucide-react";
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { call, desktop } from "../api";
import { Pane } from "../app/Pane";
import { demoPeople } from "../app/demo";
import { audioExtensions } from "../core/inbox";
import { canBeginVoiceSample, personName, voiceCount } from "../core/people";
import { Button, ContentUnavailable, FormSection, ListBar, ListBarButton, Sheet, Spinner } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText, item, popupMenu } from "../mac/native";
import type { Person, VoiceRegistration } from "../types";
import "./people.css";

const idle: VoiceRegistration = { state: "idle" };
const sampleSource = "muestra de voz";
const voiceDate = new Intl.DateTimeFormat("es-ES", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });

export function PeoplePane({ active }: { active: boolean }) {
  const [people, setPeople] = useState<Person[]>(desktop ? [] : demoPeople);
  const [selected, setSelected] = useState<string | null>(null);
  const [registering, setRegistering] = useState<string | null>(null);
  const [sample, setSample] = useState<VoiceRegistration>(idle);
  const [choosingAudio, setChoosingAudio] = useState(false);
  const [busy, setBusy] = useState(false);
  const sampleEpoch = useRef(0);
  const sampleRequest = useRef(false);
  const registeringRef = useRef<string | null>(null);

  const reload = useCallback(async () => {
    if (desktop) setPeople(await call<Person[]>("people_list"));
  }, []);

  useEffect(() => {
    if (!active || !desktop) return;
    void reload().catch((failure) => void alertMessage("No se pudo", errorText(failure)));
  }, [active, reload]);

  useEffect(() => {
    if (!desktop) return;
    let alive = true;
    let unlisten: (() => void) | undefined;
    void listen<VoiceRegistration>("escriba://voice-registration", (event) => {
      if (alive && registeringRef.current !== null) setSample(event.payload);
    }).then((stop) => {
      if (alive) unlisten = stop;
      else stop();
    }).catch((failure) => { if (alive) void alertMessage("No se pudo", errorText(failure)); });
    return () => { alive = false; unlisten?.(); };
  }, []);

  const run = async (work: () => Promise<void>) => {
    setBusy(true);
    try { await work(); }
    catch (failure) { await alertMessage("No se pudo", errorText(failure)); }
    finally { setBusy(false); }
  };
  const rename = (name: string, raw: string) => {
    const newName = personName(raw, name);
    if (!newName) return;
    void run(async () => {
      if (desktop) {
        await call("people_rename", { name, newName });
        await reload();
      } else setPeople((list) => {
        const joining = list.find((person) => person.name === newName);
        return joining
          ? list.filter((person) => person.name !== name).map((person) => person.name === newName ? { ...person, voices: [...person.voices, ...(list.find((entry) => entry.name === name)?.voices ?? [])] } : person)
          : list.map((person) => person.name === name ? { ...person, name: newName } : person);
      });
      setSelected(newName);
    });
  };
  const remove = async () => {
    if (!selected) return;
    const confirmed = await confirmDestructive(`¿Olvidar a «${selected}»?`, "Se borran sus huellas. Las grabaciones donde sale conservan el nombre.", "Olvidar");
    if (!confirmed) return;
    const name = selected;
    setSelected(null);
    void run(async () => {
      if (desktop) { await call("people_remove", { name }); await reload(); }
      else setPeople((list) => list.filter((person) => person.name !== name));
    });
  };
  const removeVoice = (id: string) => void run(async () => {
    if (desktop) { await call("people_remove_voice", { id }); await reload(); }
    else setPeople((list) => list.map((person) => ({ ...person, voices: person.voices.filter((voice) => voice.id !== id) })));
  });
  const openSample = (name: string) => {
    const epoch = ++sampleEpoch.current;
    sampleRequest.current = false;
    setChoosingAudio(false);
    registeringRef.current = name;
    setRegistering(name);
    if (desktop) void call<VoiceRegistration>("voice_registration_status").then((state) => {
      if (sampleEpoch.current === epoch) setSample(state);
    }).catch((failure) => void alertMessage("No se pudo", errorText(failure)));
  };
  const cancelSample = async () => {
    if (sample.state === "analyzing" || choosingAudio) return;
    ++sampleEpoch.current;
    sampleRequest.current = false;
    setChoosingAudio(false);
    registeringRef.current = null;
    setRegistering(null);
    setSample(idle);
    try {
      if (desktop) {
        await call<VoiceRegistration>("voice_registration_cancel");
        await call<VoiceRegistration>("voice_registration_dismiss");
      }
    } catch (failure) { await alertMessage("No se pudo", errorText(failure)); }
  };
  const startSample = async (name: string) => {
    if (sampleRequest.current || !canBeginVoiceSample(name, sample.state)) return;
    sampleRequest.current = true;
    const epoch = sampleEpoch.current;
    setSample({ state: "requesting", person: name.trim() });
    try {
      const state = await call<VoiceRegistration>("voice_registration_start", { name });
      if (sampleEpoch.current === epoch) setSample(state);
    } catch (failure) { if (sampleEpoch.current === epoch) setSample({ state: "failed", message: errorText(failure) }); }
    finally { if (sampleEpoch.current === epoch) sampleRequest.current = false; }
  };
  const finishSample = async (name: string, state: VoiceRegistration, epoch: number) => {
    if (sampleEpoch.current !== epoch) return;
    setSample(state);
    if (state.state !== "idle") return;
    registeringRef.current = null;
    setRegistering(null);
    setSelected(name.trim());
    await reload().catch((failure) => void alertMessage("No se pudo", errorText(failure)));
  };
  const stopSample = async (name: string) => {
    if (sampleRequest.current || sample.state !== "recording") return;
    sampleRequest.current = true;
    const epoch = sampleEpoch.current;
    setSample({ state: "analyzing", person: name.trim() });
    try {
      const state = await call<VoiceRegistration>("voice_registration_stop");
      await finishSample(name, state, epoch);
    } catch (failure) { if (sampleEpoch.current === epoch) setSample({ state: "failed", message: errorText(failure) }); }
    finally { if (sampleEpoch.current === epoch) sampleRequest.current = false; }
  };
  const importSample = async (name: string) => {
    if (sampleRequest.current || !canBeginVoiceSample(name, sample.state)) return;
    sampleRequest.current = true;
    setChoosingAudio(true);
    const epoch = sampleEpoch.current;
    try {
      const chosen = await open({ multiple: false, directory: false, filters: [{ name: "Audio", extensions: audioExtensions }] });
      if (sampleEpoch.current !== epoch || typeof chosen !== "string") return;
      setChoosingAudio(false);
      setSample({ state: "analyzing", person: name.trim() });
      const state = await call<VoiceRegistration>("voice_registration_import", { name, path: chosen });
      await finishSample(name, state, epoch);
    } catch (failure) { if (sampleEpoch.current === epoch) setSample({ state: "failed", message: errorText(failure) }); }
    finally {
      if (sampleEpoch.current === epoch) {
        sampleRequest.current = false;
        setChoosingAudio(false);
      }
    }
  };
  const move = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const index = people.findIndex((person) => person.name === selected);
    const next = people[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), people.length - 1)];
    if (next) setSelected(next.name);
  };
  const person = people.find((entry) => entry.name === selected);

  return (
    <Pane title="Personas">
      <div className="people-layout">
        <div className="people-list">
          <div className="people-list-items" role="listbox" aria-label="Personas" tabIndex={0} onKeyDown={move}>
            {people.map((entry) => <div key={entry.name} role="option" aria-selected={entry.name === selected} className={`list-row people-row ${entry.name === selected ? "selected" : ""}`} onMouseDown={() => setSelected(entry.name)}>
              <span>{entry.name}</span>
              <span className="font-caption secondary">{voiceCount(entry.voices.length)}</span>
            </div>)}
          </div>
          <ListBar>
            <ListBarButton icon={Plus} label="Registrar la voz de alguien" onClick={() => openSample("")} />
            <ListBarButton icon={Minus} label="Olvidar a esta persona y sus huellas" disabled={!person || busy} onClick={() => void remove()} />
          </ListBar>
        </div>
        <div className="people-divider" />
        <div className="people-detail">
          {person ? <PersonDetail key={person.name} person={person} others={people.map((entry) => entry.name).filter((name) => name !== person.name)} busy={busy} onRename={rename} onRemoveVoice={removeVoice} onRegister={openSample} />
            : <ContentUnavailable title="Sin persona elegida" icon={Users} description="Una persona aparece al renombrar a un hablante en una grabación (Hablantes → Renombrar…) o al registrar su voz con +. Escriba la reconoce en las grabaciones siguientes." />}
        </div>
      </div>
      {registering !== null && <SampleSheet initialName={registering} sample={sample} choosingAudio={choosingAudio} onStart={startSample} onStop={stopSample} onImport={importSample} onCancel={() => void cancelSample()} />}
    </Pane>
  );
}

function PersonDetail({ person, others, busy, onRename, onRemoveVoice, onRegister }: {
  person: Person; others: string[]; busy: boolean; onRename: (name: string, raw: string) => void; onRemoveVoice: (id: string) => void; onRegister: (name: string) => void;
}) {
  const [name, setName] = useState(person.name);
  return <div className="form-pane people-form">
    <FormSection footer="Pulsa Intro para cambiar el nombre. Si ya hay alguien con ese nombre, se juntan sus huellas.">
      <div className="form-row"><span className="form-label">Nombre</span><input className="inline-field selectable" aria-label="Nombre" value={name} onChange={(event) => setName(event.target.value)} onKeyDown={(event) => event.key === "Enter" && onRename(person.name, name)} disabled={busy} /></div>
      {others.length > 0 && <div className="form-row form-row-free"><Button disabled={busy} onClick={() => void popupMenu(others.map((other) => item(other, () => onRename(person.name, other))))}>Juntar con…</Button></div>}
    </FormSection>
    <FormSection header="Huellas" footer="Cada vez que renombras a alguien en una grabación o registras su voz se añade una huella, y Escriba compara con la más cercana. Las huellas no salen de este Mac.">
      {person.voices.map((voice) => <div className="form-row people-voice" key={voice.id}>
        {voice.source === sampleSource ? <Mic size={16} className="secondary" /> : <AudioLines size={16} className="secondary" />}
        <div className="people-voice-info"><span>{voice.source === sampleSource ? "Muestra de voz" : voice.source}</span><span className="font-caption secondary">{voiceDate.format(new Date(voice.addedAt))}</span></div>
        <button type="button" className="people-voice-remove" title="Quitar esta huella" aria-label="Quitar esta huella" disabled={busy} onClick={() => onRemoveVoice(voice.id)}><Trash2 size={15} /></button>
      </div>)}
      <div className="form-row form-row-free"><Button disabled={busy} onClick={() => onRegister(person.name)}>Registrar su voz…</Button></div>
    </FormSection>
  </div>;
}

function SampleSheet({ initialName, sample, choosingAudio, onStart, onStop, onImport, onCancel }: { initialName: string; sample: VoiceRegistration; choosingAudio: boolean; onStart: (name: string) => void; onStop: (name: string) => void; onImport: (name: string) => void; onCancel: () => void }) {
  const [name, setName] = useState(initialName);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (sample.state !== "recording") return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [sample.state]);
  const busy = sample.state === "requesting" || sample.state === "recording" || sample.state === "analyzing";
  const seconds = Math.max(0, Math.floor((now - new Date(sample.startedAt ?? now).getTime()) / 1000));
  const clock = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  return <Sheet onCancel={onCancel}>
    <div className="people-sample" onKeyDown={(event) => {
      if (event.key !== "Enter" || event.target instanceof HTMLButtonElement) return;
      if (choosingAudio || sample.state === "requesting" || sample.state === "analyzing") return;
      if (sample.state !== "recording" && !canBeginVoiceSample(name, sample.state)) return;
      event.preventDefault();
      if (sample.state === "recording") onStop(name);
      else onStart(name);
    }}>
      <div className="font-headline">Registrar una voz</div>
      <input className="text-field selectable" aria-label="Nombre" placeholder="Nombre" value={name} autoFocus onChange={(event) => setName(event.target.value)} disabled={busy || choosingAudio} />
      <p className="font-callout secondary">Pulsa Grabar y habla con normalidad durante un minuto, por ejemplo leyendo un texto en voz alta. Hacen falta al menos 30 segundos de voz. También puedes elegir un audio con al menos 30 segundos de voz; el original se conserva. Si grabas con el micrófono, el audio de la muestra se borra al terminar: solo queda su huella, que no sale de este Mac.</p>
      {sample.state === "requesting" && <div className="people-sample-status"><Spinner />Pidiendo permiso para el micrófono…</div>}
      {sample.state === "recording" && <div className="people-sample-status"><CircleDot size={16} color="var(--red)" /> <span className="people-clock">{clock}</span></div>}
      {sample.state === "analyzing" && <div className="people-sample-status"><Spinner />Sacando la huella…</div>}
      {sample.state === "failed" && <div className="people-sample-error"><TriangleAlert size={16} /><span>{sample.message}</span></div>}
      <div className="sheet-actions"><Button disabled={sample.state === "analyzing" || choosingAudio} onClick={onCancel}>Cancelar</Button>
        {sample.state !== "recording" && <Button disabled={!canBeginVoiceSample(name, sample.state) || choosingAudio} onClick={() => onImport(name)}>Elegir audio…</Button>}
        {sample.state === "recording" ? <Button prominent onClick={() => onStop(name)}>Terminar</Button> : <Button prominent disabled={!canBeginVoiceSample(name, sample.state) || choosingAudio} onClick={() => onStart(name)}>Grabar</Button>}
      </div>
    </div>
  </Sheet>;
}
