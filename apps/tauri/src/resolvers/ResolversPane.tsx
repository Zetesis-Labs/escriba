import { AlertTriangle, CheckCircle2, Globe, Laptop, Minus, Plus, Sparkles, AudioWaveform } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { call, desktop, native } from "../api";
import { Pane } from "../app/Pane";
import {
  bytesLabel,
  localId,
  localName,
  localProblem,
  nextResolverName,
  presetFor,
  remotePresets,
  remoteURLProblem,
  resolverProblem,
  resolverSubtitle,
  roleLabel,
  sampleInstructions,
  sampleTranscript,
  type Role,
} from "../core/resolvers";
import { Button, ContentUnavailable, FormRow, FormSection, InlineField, LabeledRow, ListBar, ListBarButton, PopupButton, Spinner } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText, item, popupMenu } from "../mac/native";
import type { Digest, Resolver, Snapshot } from "../types";
import "./resolvers.css";

type NativeStatus = { whisper?: { available?: boolean; model?: string }; llm?: { available?: boolean; reason?: string | null } };

function useNativeStatus(model: string) {
  const [status, setStatus] = useState<NativeStatus | null>(null);
  const reload = useCallback(() => {
    if (!desktop) return;
    void native<NativeStatus>("status", { model })
      .then(setStatus)
      .catch(() => setStatus(null));
  }, [model]);
  useEffect(reload, [reload]);
  return { status, reload };
}

export function ResolversPane({ data, role, refresh }: { data: Snapshot; role: Role; refresh: () => Promise<void> }) {
  const resolvers = [...data.resolvers.filter((resolver) => resolver.role === role)].sort((a, b) => Number(b.local) - Number(a.local));
  const [chosen, setSelected] = useState<string>(localId(role));
  const selected = resolvers.some((resolver) => resolver.id === chosen) ? chosen : (resolvers.find((resolver) => resolver.local)?.id ?? chosen);
  const { status, reload } = useNativeStatus(data.settings.whisperModel);
  const local = localProblem(role, status);
  const current = resolvers.find((resolver) => resolver.id === selected);

  const add = async (event: React.MouseEvent<HTMLButtonElement>) => {
    await popupMenu(
      remotePresets(role).map((preset) =>
        item(preset.name, () => {
          const created: Resolver = {
            id: crypto.randomUUID(),
            name: nextResolverName(preset.name, resolvers.map((resolver) => resolver.name)),
            role,
            local: false,
            enabled: true,
            url: preset.baseURL,
            model: preset.model,
          };
          void call("config_save", { collection: "resolvers", item: created })
            .then(async () => {
              await refresh();
              setSelected(created.id);
            })
            .catch((failure) => alertMessage("No se pudo", errorText(failure)));
        }),
      ),
      event.currentTarget,
    );
  };
  const remove = async () => {
    if (!current || current.local) return;
    const confirmed = await confirmDestructive(`¿Quitar «${current.name}»?`, `Se borra su clave. Las recetas que lo usaban pasan a ${localName(role)}.`, "Quitar");
    if (!confirmed) return;
    try {
      await call("config_remove", { collection: "resolvers", id: current.id });
      await call("credential_save", { id: current.id, value: "" }).catch(() => undefined);
      setSelected(localId(role));
    } catch (failure) {
      await alertMessage("No se pudo", errorText(failure));
    } finally {
      await refresh();
    }
  };

  return (
    <Pane title={roleLabel(role)}>
      <div className="list-detail">
        <div className="side-list" style={{ width: 250 }}>
          <div className="side-list-items" role="listbox" aria-label={roleLabel(role)} tabIndex={0}>
            {resolvers.map((resolver) => {
              const problem = resolverProblem(resolver, local);
              return (
                <div
                  key={resolver.id}
                  role="option"
                  aria-selected={resolver.id === selected}
                  className={`list-row resolver-row ${resolver.id === selected ? "selected" : ""}`}
                  onMouseDown={() => setSelected(resolver.id)}
                >
                  {resolver.local ? <Laptop size={15} strokeWidth={1.7} className="secondary" /> : <Globe size={15} strokeWidth={1.7} className="secondary" />}
                  <div className="resolver-row-text">
                    <div>{resolver.local ? localName(role) : resolver.name}</div>
                    <div className={`font-caption ${problem && !resolver.local ? "warning" : "secondary"}`}>{resolverSubtitle(resolver, problem)}</div>
                  </div>
                </div>
              );
            })}
          </div>
          <ListBar>
            <ListBarButton icon={Plus} label="Añadir un servicio compatible con OpenAI" onClick={(event) => void add(event)} />
            <ListBarButton icon={Minus} label="Quitar" onClick={() => void remove()} disabled={!current || current.local} />
          </ListBar>
        </div>
        <div className="list-detail-divider" />
        <div className="detail-column">
          {current ? (
            <ResolverEditor key={current.id} resolver={current} role={role} localProblem={local} whisperModel={data.settings.whisperModel} refresh={refresh} reloadStatus={reload} />
          ) : (
            <ContentUnavailable title="Sin resolutor elegido" icon={role === "llm" ? Sparkles : AudioWaveform} description="Elige uno de la lista o añade un servicio con +." />
          )}
        </div>
      </div>
    </Pane>
  );
}

type Trial = { kind: "digest"; digest: Digest } | { kind: "transcript"; text: string } | null;

function ResolverEditor({
  resolver,
  role,
  localProblem: local,
  whisperModel,
  refresh,
  reloadStatus,
}: {
  resolver: Resolver;
  role: Role;
  localProblem: string | null;
  whisperModel: string;
  refresh: () => Promise<void>;
  reloadStatus: () => void;
}) {
  const [name, setName] = useState(resolver.name);
  const [url, setURL] = useState(resolver.url ?? "");
  const [model, setModel] = useState(resolver.model ?? "");
  const [key, setKey] = useState("");
  const [models, setModels] = useState<string[]>([]);
  const [working, setWorking] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [trial, setTrial] = useState<Trial>(null);
  const draft = { ...resolver, name, url, model };
  const dirty = name !== resolver.name || url !== (resolver.url ?? "") || model !== (resolver.model ?? "") || key.trim() !== "";
  const readiness = resolverProblem(draft, local);
  const keyPayload = { resolver: { url, model, local: resolver.local }, resolverId: resolver.id, key };

  const discard = () => {
    setName(resolver.name);
    setURL(resolver.url ?? "");
    setModel(resolver.model ?? "");
    setKey("");
    setProblem(null);
    setTrial(null);
  };
  const save = async () => {
    try {
      await call("config_save", { collection: "resolvers", item: { ...resolver, name: name.trim() || resolver.name, url: url.trim(), model: model.trim(), enabled: true } });
      if (key.trim()) await call("credential_save", { id: resolver.id, value: key.trim() });
      setKey("");
    } catch (failure) {
      await alertMessage("No se pudo guardar", errorText(failure));
    } finally {
      await refresh();
    }
  };
  const loadModels = async () => {
    setWorking(true);
    setProblem(null);
    try {
      setModels(await call<string[]>("resolver_models", keyPayload));
    } catch (failure) {
      setModels([]);
      setProblem(errorText(failure));
    } finally {
      setWorking(false);
    }
  };
  const tryIt = async () => {
    setWorking(true);
    setProblem(null);
    setTrial(null);
    try {
      const result = await call<Record<string, unknown>>("resolver_try", { ...keyPayload, role, instructions: sampleInstructions, prompt: sampleTranscript });
      setTrial(
        role === "llm"
          ? { kind: "digest", digest: { title: String(result.title ?? ""), summary: String(result.summary ?? ""), tags: Array.isArray(result.tags) ? result.tags.map(String) : [] } }
          : { kind: "transcript", text: String(result.text ?? "") },
      );
    } catch (failure) {
      setProblem(errorText(failure));
    } finally {
      setWorking(false);
    }
  };
  const presetOptions = remotePresets(role).map((preset) => ({ value: preset.name, label: preset.name }));
  const applyPreset = (presetName: string) => {
    const preset = remotePresets(role).find((candidate) => candidate.name === presetName);
    if (!preset) return;
    setURL(preset.baseURL);
    if (preset.model) setModel(preset.model);
    setModels([]);
  };

  return (
    <div className="editor">
      <div className="form-pane">
        <FormSection
          footer={
            role === "stt"
              ? `Cada receta elige con qué transcribir, en Recetas. La que no elige usa ${localName(role)}.`
              : `Cada receta elige con qué resumir, en Recetas. La que no elige usa ${localName(role)}.`
          }
        >
          <LabeledRow label="Nombre">{resolver.local ? localName(role) : <InlineField value={name} onChange={setName} />}</LabeledRow>
          {readiness && (
            <FormRow>
              <span className="font-caption secondary readiness">
                <AlertTriangle size={12} strokeWidth={2} /> {readiness.charAt(0).toUpperCase() + readiness.slice(1)}
              </span>
            </FormRow>
          )}
        </FormSection>

        {resolver.local && role === "stt" && <WhisperModelSection model={whisperModel} onChange={reloadStatus} />}
        {resolver.local && (
          <FormSection>
            <FormRow>
              <span className="font-caption secondary">
                {role === "stt"
                  ? "Whisper transcribe en el propio Mac y es el único que detecta hablantes. El audio no sale de aquí."
                  : "Apple Intelligence resume en el propio Mac: nada del audio ni del texto sale de aquí. Su ventana es pequeña, así que una nota larga se resume por trozos."}
              </span>
            </FormRow>
          </FormSection>
        )}

        {!resolver.local && (
          <FormSection
            header="Servicio compatible con OpenAI"
            footer={
              role === "stt"
                ? "El audio de cada nota sale del Mac hacia este servicio. Con un servicio remoto no se detectan hablantes. OpenAI y Groq admiten audios de hasta 25 MB."
                : "El texto de cada nota sale del Mac hacia este servicio. Sirve cualquier API compatible con OpenAI: OpenAI, OpenRouter, Groq o, en tu red, LM Studio y Ollama."
            }
          >
            <LabeledRow label="Servicio">
              <PopupButton label="Servicio" value={presetFor(role, url)} options={presetOptions} onChange={applyPreset} />
            </LabeledRow>
            <LabeledRow label="URL de la API">
              <InlineField value={url} onChange={setURL} placeholder="https://api.openai.com/v1" />
            </LabeledRow>
            <LabeledRow label="Clave">
              <InlineField value={key} onChange={setKey} secure placeholder={resolver.hasCredential ? "••••••••••••" : "Vacía si el servicio no la pide"} />
            </LabeledRow>
            <LabeledRow label="Modelo">
              <InlineField value={model} onChange={setModel} placeholder={role === "stt" ? "whisper-1" : "Escribe o carga la lista"} />
              {models.length > 0 && (
                <PopupButton
                  label="Modelos"
                  value={"__"}
                  options={[{ value: "__", label: `${models.length} modelos` }, ...models.map((id) => ({ value: id, label: id }))].slice(0, 400)}
                  onChange={(id) => id !== "__" && setModel(id)}
                />
              )}
              <Button small onClick={() => void loadModels()} disabled={Boolean(remoteURLProblem(url)) || working}>
                Cargar modelos
              </Button>
            </LabeledRow>
          </FormSection>
        )}

        {(role === "llm" || !resolver.local) && (
          <FormSection
            header="Probar"
            footer={
              role === "llm"
                ? "Resume una conversación corta de ejemplo con lo que hay escrito, antes de guardar."
                : "Manda un segundo de silencio con lo que hay escrito, antes de guardar."
            }
          >
            <FormRow>
              <Button onClick={() => void tryIt()} disabled={Boolean(readiness) || working}>
                {role === "llm" ? "Resumir la nota de ejemplo" : "Transcribir un audio de prueba"}
              </Button>
              {working && <Spinner />}
            </FormRow>
            {problem && (
              <FormRow>
                <span className="font-caption trial-problem selectable">{problem}</span>
              </FormRow>
            )}
            {trial?.kind === "digest" && (
              <FormRow>
                <div className="trial-digest selectable">
                  <div className="font-headline">{trial.digest.title}</div>
                  <div>{trial.digest.summary}</div>
                  {trial.digest.tags.length > 0 && <div className="secondary">{trial.digest.tags.map((tag) => `#${tag}`).join(" ")}</div>}
                </div>
              </FormRow>
            )}
            {trial?.kind === "transcript" && (
              <FormRow>
                <span className="trial-ok">
                  <CheckCircle2 size={14} strokeWidth={1.8} /> {trial.text ? `El servicio responde: «${trial.text}»` : "El servicio acepta el audio y responde."}
                </span>
              </FormRow>
            )}
          </FormSection>
        )}
      </div>
      <div className="bottom-bar">
        {dirty && <span className="font-caption secondary">Cambios sin guardar</span>}
        <span className="grow" />
        <Button onClick={discard} disabled={!dirty}>
          Descartar
        </Button>
        <Button prominent onClick={() => void save()} disabled={!dirty}>
          Guardar
        </Button>
      </div>
    </div>
  );
}

function WhisperModelSection({ model, onChange }: { model: string; onChange: () => void }) {
  const [info, setInfo] = useState<{ model: string; available: boolean; bytes: number } | null>(null);
  const [downloading, setDownloading] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const load = useCallback(() => {
    if (!desktop) return;
    void call<{ model: string; available: boolean; bytes: number }>("whisper_model", { action: "info" })
      .then(setInfo)
      .catch((error) => setFailure(errorText(error)));
  }, []);
  useEffect(load, [load, model]);
  const download = async () => {
    setDownloading(true);
    setFailure(null);
    try {
      await native("downloadModel", { model });
    } catch (error) {
      setFailure(errorText(error));
    } finally {
      setDownloading(false);
      load();
      onChange();
    }
  };
  const remove = async () => {
    try {
      await call("whisper_model", { action: "delete" });
    } catch (error) {
      setFailure(errorText(error));
    } finally {
      load();
      onChange();
    }
  };
  return (
    <FormSection header="Modelo">
      <LabeledRow label="Modelo">{info?.model ?? model}</LabeledRow>
      {info?.available ? (
        <>
          <LabeledRow label="Estado">{`descargado${info.bytes ? ` · ${bytesLabel(info.bytes)}` : ""}`}</LabeledRow>
          <FormRow>
            <Button onClick={() => void remove()}>
              <span className="destructive-text">Borrar del disco</span>
            </Button>
          </FormRow>
          <FormRow>
            <span className="font-caption secondary">Sin el modelo no se transcribe nada en este Mac hasta volver a descargarlo.</span>
          </FormRow>
        </>
      ) : downloading ? (
        <FormRow>
          <Spinner /> <span className="secondary">Descargando…</span>
        </FormRow>
      ) : (
        <>
          <LabeledRow label="Estado">no descargado</LabeledRow>
          <FormRow>
            <Button onClick={() => void download()}>Descargar (unos 3 GB)</Button>
          </FormRow>
        </>
      )}
      {failure && (
        <FormRow>
          <span className="font-caption trial-problem selectable">{failure}</span>
        </FormRow>
      )}
    </FormSection>
  );
}
