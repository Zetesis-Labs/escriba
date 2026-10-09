import { run, type Result } from "@escriba/conectores";
import { open } from "@tauri-apps/plugin-dialog";
import { useEffect, useState, type ReactNode } from "react";
import { call, desktop } from "../api";
import { chooseNotionSource, connectorProblem, newOKFDocument, notionConfiguration, okfConfiguration, removeOKFProperty, writableColumns, type NotionConfiguration, type NotionSource, type OKFConfiguration, type OKFDocument } from "../core/connectors";
import { notionPreview } from "../core/notionPreview";
import { abbreviatedPath } from "../core/settings";
import { Button, FormRow, FormSection, InlineField, LabeledRow, PopupButton, Segmented, Spinner, Toggle } from "../mac/controls";
import { alertMessage, errorText } from "../mac/native";
import { discoverDestination } from "../runtime";
import type { Account, Destination } from "../types";
import { TokenEditor } from "./TokenEditor";

type PreviewFile = { documentID: string; path: string; contents: string };

function SaveBar({ dirty, busy, discard, save }: { dirty: boolean; busy: boolean; discard: () => void; save: () => void }) {
  return (
    <div className="bottom-bar connector-save-bar">
      {dirty && <span className="font-caption secondary">Cambios sin guardar</span>}
      <span className="grow" />
      <Button disabled={!dirty || busy} onClick={discard}>Descartar</Button>
      <Button prominent disabled={!dirty || busy} onClick={save}>Guardar</Button>
    </div>
  );
}

function SectionText({ children, problem, warning }: { children: ReactNode; problem?: boolean; warning?: boolean }) {
  return <div className={`font-caption ${problem ? "connector-error" : warning ? "connector-problem" : "secondary"}`}>{children}</div>;
}

function NotionEditor({ account, destination, refresh }: { account: Account; destination: Destination; refresh: () => Promise<void> }) {
  const saved = notionConfiguration(destination.configuration);
  const [draft, setDraft] = useState<NotionConfiguration>(saved);
  const [name, setName] = useState(destination.name);
  const [enabled, setEnabled] = useState(destination.enabled);
  const [token, setToken] = useState("");
  const [hasCredential, setHasCredential] = useState(account.hasCredential === true);
  const [sources, setSources] = useState<NotionSource[]>(!desktop && saved.source.id ? [saved.source] : []);
  const [busy, setBusy] = useState(false);
  const [phaseProblem, setPhaseProblem] = useState<string | null>(null);
  const [preview, setPreview] = useState<ReturnType<typeof notionPreview> | null>(null);
  const [previewProblem, setPreviewProblem] = useState<string | null>(null);
  const dirty = name !== destination.name || enabled !== destination.enabled || JSON.stringify(draft) !== JSON.stringify(saved) || !!token.trim();
  const pending = connectorProblem({ ...account, hasCredential }, { ...destination, configuration: draft }, token);
  const selected = draft.source.id ? draft.source : null;

  useEffect(() => {
    if (!selected) {
      setPreview(null);
      setPreviewProblem(null);
      return;
    }
    let alive = true;
    void run({ operation: "preview", provider: "notion", config: { source: draft.source, columns: draft.columns, body: draft.body } }).then((result) => {
      if (alive) { setPreview(notionPreview(result, draft.source)); setPreviewProblem(null); }
    }).catch((failure) => { if (alive) { setPreview(null); setPreviewProblem(errorText(failure)); } });
    return () => { alive = false; };
  }, [draft, selected]);

  const discard = () => {
    setDraft(saved);
    setName(destination.name);
    setEnabled(destination.enabled);
    setToken("");
    setPhaseProblem(null);
  };
  const save = async () => {
    setBusy(true);
    try {
      await call("connector_save", { account: { ...account, name, enabled: true }, destination: { ...destination, name, enabled, configuration: draft } });
      if (token.trim()) {
        await call("credential_save", { id: destination.id, value: token.trim() });
        setHasCredential(true);
        setToken("");
      }
      await refresh();
    } catch (failure) {
      await alertMessage("No se pudo guardar", errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const connect = async () => {
    if (!token.trim() && !hasCredential) return;
    setBusy(true);
    setPhaseProblem(null);
    try {
      if (token.trim()) {
        await call("credential_save", { id: destination.id, value: token.trim() });
        setHasCredential(true);
        setToken("");
      }
      const result = await discoverDestination(destination.id);
      const resources = Array.isArray(result.resources) ? result.resources : [];
      const found = resources.flatMap((entry) => {
        if (!entry || typeof entry !== "object" || Array.isArray(entry) || !entry.schema) return [];
        const parsed = notionConfiguration({ source: entry.schema, columns: {}, body: "" }).source;
        return parsed.id ? [parsed] : [];
      });
      setSources(found);
      if (!found.length) setPhaseProblem("La integración no tiene acceso a ninguna base. Compártele una desde Notion.");
      const fresh = found.find((source) => source.id === draft.source.id);
      if (fresh) setDraft((current) => chooseNotionSource(current, fresh));
      await refresh();
    } catch (failure) {
      setSources([]);
      setPhaseProblem(errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const disconnect = async () => {
    setBusy(true);
    try {
      await call("credential_save", { id: destination.id, value: "" });
      const cleared = notionConfiguration({});
      await call("connector_save", { account, destination: { ...destination, enabled: false, configuration: cleared } });
      setHasCredential(false);
      setToken("");
      setSources([]);
      setPhaseProblem(null);
      setDraft(cleared);
      setEnabled(false);
      await refresh();
    } catch (failure) {
      await alertMessage("No se pudo desconectar", errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const choose = (id: string) => {
    const source = sources.find((candidate) => candidate.id === id);
    if (source) setDraft((current) => chooseNotionSource(current, source));
  };
  const columns = selected ? writableColumns(selected) : [];
  const typeLabels: Record<string, string> = { title: "título", rich_text: "texto", multi_select: "selección múltiple", select: "selección", date: "fecha", number: "número", url: "URL" };

  return (
    <form className="connector-editor" onSubmit={(event) => { event.preventDefault(); if (dirty && !busy) void save(); }}>
      <button type="submit" hidden>Guardar</button>
      <div className="form-pane connector-form">
        <FormSection>
          <LabeledRow label="Nombre"><InlineField value={name} onChange={setName} /></LabeledRow>
          <LabeledRow label="Publicar cada transcripción nueva">
            <fieldset disabled={!!pending} className="connector-toggle-fieldset">
              <Toggle checked={enabled} onChange={setEnabled} label="Publicar cada transcripción nueva" />
            </fieldset>
          </LabeledRow>
          <FormRow><SectionText>{pending ?? "Corregir hablantes o reprocesar regenera la página ya publicada."}</SectionText></FormRow>
        </FormSection>
        <FormSection header="Conexión con Notion" footer="En Notion: Ajustes → Conexiones → nueva conexión con «Token de acceso», dale acceso a las bases que quieras y pega aquí el token. Si añades columnas a la base, pulsa «Actualizar».">
          <FormRow><input className="text-field" type="password" value={token} onChange={(event) => setToken(event.target.value)} placeholder="Token de la integración" aria-label="Token de la integración" autoComplete="off" /></FormRow>
          <FormRow>
            <Button disabled={busy || (!token.trim() && !hasCredential)} onClick={() => void connect()}>{sources.length ? "Actualizar bases y columnas" : "Conectar"}</Button>
            {busy && <Spinner />}
            <span className="grow" />
            {(hasCredential || token) && <button className="connector-danger" type="button" disabled={busy} onClick={() => void disconnect()}>Desconectar</button>}
          </FormRow>
          {phaseProblem && <FormRow><SectionText problem>{phaseProblem}</SectionText></FormRow>}
        </FormSection>
        {sources.length > 0 && (
          <FormSection header="Base de datos">
            <LabeledRow label="Guardar en">
              <PopupButton value={selected?.id ?? ""} label="Guardar en" onChange={choose} options={[
                { value: "", label: "Sin elegir" },
                ...sources.map((source) => ({ value: source.id, label: source.databaseTitle === source.title || !source.title ? source.databaseTitle : `${source.databaseTitle} › ${source.title}` })),
              ]} />
            </LabeledRow>
          </FormSection>
        )}
        {selected && (
          <>
            <FormSection header="Propiedades" footer="Una fila por columna de tu base: escribe qué va en ella, con texto y datos. Vacía, Escriba no la toca. Las columnas de casilla, persona, archivo o relación no aparecen porque Escriba no escribe en ellas.">
              {columns.map((column) => (
                <FormRow key={column.name}>
                  <div className="connector-column-label"><span>{column.name}</span><span className="font-caption secondary">{typeLabels[column.type]}</span></div>
                  <TokenEditor value={draft.columns[column.name] ?? ""} onChange={(value) => setDraft((current) => ({ ...current, columns: { ...current.columns, [column.name]: value } }))} context="property" placeholder="No se exporta" />
                </FormRow>
              ))}
            </FormSection>
            <FormSection header="Cuerpo de la página" footer="Escribe como en una página: # para títulos, - para viñetas, **negrita**. Pulsa / para insertar un dato; el dato Audio sube el fichero a Notion. Una línea cuyos datos salen vacíos no se escribe.">
              <FormRow><TokenEditor value={draft.body} onChange={(body) => setDraft((current) => ({ ...current, body }))} context="body" placeholder="Escribe aquí. Pulsa / para insertar un dato." multiline /></FormRow>
            </FormSection>
            {preview && <FormSection header="Así queda" footer="Con una grabación de ejemplo. Se actualiza mientras escribes, antes de guardar.">
              <div className="connector-preview">
                <div className="connector-preview-grid">{preview.properties.map((property) => <div className="connector-preview-row" key={property.name}><span className="secondary">{property.name}</span><span>{property.value}</span></div>)}</div>
                <div className="connector-preview-body">{preview.text}</div>
              </div>
            </FormSection>}
            {previewProblem && <FormSection header="Así queda"><FormRow><SectionText problem>{previewProblem}</SectionText></FormRow></FormSection>}
          </>
        )}
      </div>
      <SaveBar dirty={dirty} busy={busy} discard={discard} save={() => void save()} />
    </form>
  );
}

function OKFEditor({ account, destination, refresh, home }: { account: Account; destination: Destination; refresh: () => Promise<void>; home: string | null }) {
  const saved = okfConfiguration(destination.configuration);
  const [draft, setDraft] = useState<OKFConfiguration>(saved);
  const [name, setName] = useState(destination.name);
  const [enabled, setEnabled] = useState(destination.enabled);
  const [chosen, setChosen] = useState<string | null>(saved.documents[0]?.id ?? null);
  const [preview, setPreview] = useState<PreviewFile[]>([]);
  const [previewProblem, setPreviewProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const selected = draft.documents.find((document) => document.id === chosen) ?? draft.documents[0];
  const pending = connectorProblem(account, { ...destination, configuration: draft });
  const dirty = name !== destination.name || enabled !== destination.enabled || JSON.stringify(draft) !== JSON.stringify(saved);
  useEffect(() => {
    let alive = true;
    if (!draft.documents.length) { setPreview([]); setPreviewProblem(null); return; }
    void run({ operation: "preview", provider: "okf", config: { ...draft, folder: draft.folder || "/" } }).then((result: Result) => {
      const files = Array.isArray(result.files) ? result.files.flatMap((file) => {
        if (!file || typeof file !== "object" || Array.isArray(file) || typeof file.documentID !== "string" || typeof file.path !== "string" || typeof file.contents !== "string") return [];
        return [{ documentID: file.documentID, path: file.path, contents: file.contents }];
      }) : [];
      if (alive) { setPreview(files); setPreviewProblem(null); }
    }).catch((failure) => { if (alive) { setPreview([]); setPreviewProblem(errorText(failure)); } });
    return () => { alive = false; };
  }, [draft]);
  const updateDocument = (id: string, change: (document: OKFDocument) => OKFDocument) => setDraft((current) => ({ ...current, documents: current.documents.map((document) => document.id === id ? change(document) : document) }));
  const discard = () => { setDraft(saved); setName(destination.name); setEnabled(destination.enabled); setChosen(saved.documents[0]?.id ?? null); };
  const save = async () => {
    setBusy(true);
    try {
      await call("connector_save", { account: { ...account, name, folder: draft.folder, enabled: true }, destination: { ...destination, name, enabled, configuration: draft } });
      await refresh();
    } catch (failure) {
      await alertMessage("No se pudo guardar", errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const chooseFolder = async () => {
    const path = await open({ directory: true, title: "Elegir carpeta del bundle" });
    if (typeof path === "string") setDraft((current) => ({ ...current, folder: path }));
  };
  const links = draft.documents.map((document) => ({ id: document.id, name: document.name }));
  const file = preview.find((candidate) => candidate.documentID === selected?.id);
  return (
    <form className="connector-editor" onSubmit={(event) => { event.preventDefault(); if (dirty && !busy) void save(); }}>
      <button type="submit" hidden>Guardar</button>
      <div className="form-pane connector-form">
        <FormSection>
          <LabeledRow label="Nombre"><InlineField value={name} onChange={setName} /></LabeledRow>
          <LabeledRow label="Exportar cada transcripción nueva"><fieldset disabled={!!pending} className="connector-toggle-fieldset"><Toggle checked={enabled} onChange={setEnabled} label="Exportar cada transcripción nueva" /></fieldset></LabeledRow>
          <FormRow><SectionText warning={!!pending}>{pending ?? "Corregir hablantes, reprocesar o resumir reescribe los ficheros ya exportados."}</SectionText></FormRow>
        </FormSection>
        <FormSection header="Carpeta del bundle" footer="Escriba gestiona esta carpeta como un bundle OKF: escribe los documentos, un index.md en cada carpeta y log.md. Si va dentro de un bundle más grande, elige una subcarpeta propia.">
          <FormRow>
            <span className="connector-folder" title={draft.folder}>{draft.folder ? abbreviatedPath(draft.folder, home) : "Sin elegir"}</span>
            {draft.folder && <Button small onClick={() => void call("reveal", { path: draft.folder }).catch((failure) => alertMessage("No se pudo", errorText(failure)))}>Mostrar en Finder</Button>}
            <Button small onClick={() => void chooseFolder()}>Elegir…</Button>
          </FormRow>
        </FormSection>
        <FormSection header="Documentos" footer="Cada grabación escribe un fichero por documento. Para enlazarlos entre sí, inserta el dato «Enlace a…».">
          <FormRow>
            <Segmented value={selected?.id ?? ""} options={draft.documents.map((document) => ({ value: document.id, label: document.name || "Sin nombre" }))} onChange={setChosen} />
            <Button small onClick={() => { const document = newOKFDocument(draft.documents.length + 1, crypto.randomUUID()); setDraft((current) => ({ ...current, documents: [...current.documents, document] })); setChosen(document.id); }}>+</Button>
            <Button small disabled={!selected} onClick={() => { if (!selected) return; setDraft((current) => ({ ...current, documents: current.documents.filter((document) => document.id !== selected.id) })); setChosen(draft.documents.find((document) => document.id !== selected.id)?.id ?? null); }}>−</Button>
          </FormRow>
        </FormSection>
        {selected && <>
          <FormSection header="Documento" footer="La ruta dentro del bundle. Escribe // para insertar un dato en ella; el título se pone sin tildes ni signos.">
            <LabeledRow label="Nombre"><InlineField value={selected.name} onChange={(name) => updateDocument(selected.id, (document) => ({ ...document, name }))} /></LabeledRow>
            <LabeledRow label="Ruta"><TokenEditor value={selected.path} onChange={(path) => updateDocument(selected.id, (document) => ({ ...document, path }))} context="path" placeholder="carpeta/[Día]-[Título].md" /></LabeledRow>
          </FormSection>
          <FormSection header="Propiedades" footer="Son el frontmatter del fichero: clave y valor, con texto y datos mezclados. type es obligatorio en OKF. Escriba añade siempre escriba_key y generated para reconocer sus ficheros.">
            {selected.properties.map((property, index) => {
              const fixed = property.key.trim() === "type" && selected.properties.findIndex((item) => item.key.trim() === "type") === index;
              return <FormRow key={property.id ?? index}>
                {fixed ? <span className="connector-property-key">type</span> : <input className="text-field connector-property-key" value={property.key} placeholder="clave" onChange={(event) => updateDocument(selected.id, (document) => ({ ...document, properties: document.properties.map((item, candidate) => candidate === index ? { ...item, key: event.target.value } : item) }))} />}
                <TokenEditor value={property.value} onChange={(value) => updateDocument(selected.id, (document) => ({ ...document, properties: document.properties.map((item, candidate) => candidate === index ? { ...item, value } : item) }))} context="property" links={links} current={selected.id} placeholder="valor" />
                {!fixed && <button className="connector-property-remove" type="button" aria-label={`Quitar propiedad ${property.key}`} onClick={() => updateDocument(selected.id, (document) => removeOKFProperty(document, index))}>⊗</button>}
              </FormRow>;
            })}
            <FormRow><Button small onClick={() => updateDocument(selected.id, (document) => ({ ...document, properties: [...document.properties, { id: crypto.randomUUID(), key: "", value: "" }] }))}>Añadir propiedad</Button></FormRow>
          </FormSection>
          <FormSection header="Cuerpo" footer="Escribe como en una página: Markdown, con # para los títulos. Pulsa / donde quieras para insertar un dato, o usa +. Una línea cuyos datos salen vacíos no se escribe.">
            <FormRow><TokenEditor value={selected.body} onChange={(body) => updateDocument(selected.id, (document) => ({ ...document, body }))} context="body" links={links} current={selected.id} placeholder="Escribe aquí. Pulsa / para insertar un dato." multiline /></FormRow>
          </FormSection>
          {file && <FormSection header="Así queda" footer="Con una grabación de ejemplo. Se actualiza mientras escribes, antes de guardar.">
            <div className="connector-preview"><div className="font-caption secondary">▤ {file.path}</div><pre>{file.contents}</pre></div>
          </FormSection>}
          {previewProblem && <FormSection header="Así queda"><FormRow><SectionText problem>{previewProblem}</SectionText></FormRow></FormSection>}
        </>}
      </div>
      <SaveBar dirty={dirty} busy={busy} discard={discard} save={() => void save()} />
    </form>
  );
}

export function ConnectorEditor({ account, destination, refresh, home }: { account: Account; destination: Destination; refresh: () => Promise<void>; home: string | null }) {
  return destination.provider === "notion"
    ? <NotionEditor account={account} destination={destination} refresh={refresh} />
    : <OKFEditor account={account} destination={destination} refresh={refresh} home={home} />;
}
