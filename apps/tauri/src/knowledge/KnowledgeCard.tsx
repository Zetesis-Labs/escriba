import { ListTree, Plus } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { call } from "../api";
import { Button, Sheet, Spinner } from "../mac/controls";
import { confirmDestructive, errorText } from "../mac/native";
import { editedFields, fieldInputText, fieldText, isInstalledOntology, isRecordPage, recordTitle, type InstalledOntology, type KnowledgeCollection, type KnowledgeRecord, type RuntimeHost } from "./model";
import "./knowledge.css";

type Group = { ontology: InstalledOntology; collection: KnowledgeCollection; records: KnowledgeRecord[]; page: number; hasMore: boolean; loading: boolean; error: string | null };
type Editor = { groupKey: string; record: KnowledgeRecord | null; raw: Record<string, string | boolean>; error: string | null; busy: boolean };
type Endpoints = { records: KnowledgeRecord[]; page: number; hasMore: boolean; loading: boolean; error: string | null };
type Attach = { groupKey: string; recordId: string; records: KnowledgeRecord[]; page: number; hasMore: boolean; loading: boolean; busy: boolean; error: string | null };
const groupKey = (ontologyId: string, table: string) => `${ontologyId}\u0000${table}`;

export function KnowledgeCard({ recordingId, versionId, host = call }: { recordingId: string; versionId?: string; host?: RuntimeHost }) {
  const [groups, setGroups] = useState<Record<string, Group>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editor, setEditor] = useState<Editor | null>(null);
  const [attach, setAttach] = useState<Attach | null>(null);
  const [endpoints, setEndpoints] = useState<Record<string, Endpoints>>({});
  const generation = useRef(0);
  const editorGeneration = useRef(0);
  const attachGeneration = useRef(0);

  const loadPage = useCallback(async (ontology: InstalledOntology, collection: KnowledgeCollection, page = 0, append = false, scope = generation.current) => {
    const key = groupKey(ontology.id, collection.table);
    if (scope !== generation.current) return;
    setGroups((current) => ({ ...current, [key]: { ontology, collection, records: append ? current[key]?.records ?? [] : [], page, hasMore: append ? current[key]?.hasMore ?? false : false, loading: true, error: null } }));
    try {
      const result = await host<unknown>("knowledge_records", { id: ontology.id, table: collection.table, recordingId, page });
      if (scope !== generation.current) return;
      if (!isRecordPage(result)) throw new Error("La página de registros no es válida.");
      setGroups((current) => ({ ...current, [key]: { ontology, collection, records: append ? [...(current[key]?.records ?? []), ...result.records] : result.records, page: result.page, hasMore: result.hasMore, loading: false, error: null } }));
    } catch (failure) {
      if (scope !== generation.current) return;
      setGroups((current) => ({ ...current, [key]: { ontology, collection, records: current[key]?.records ?? [], page: current[key]?.page ?? page, hasMore: current[key]?.hasMore ?? false, loading: false, error: errorText(failure) } }));
    }
  }, [host, recordingId]);

  useEffect(() => {
    const scope = ++generation.current;
    let current = true;
    setGroups({});
    setLoading(true);
    setError(null);
    void host<unknown>("knowledge_list").then((result) => {
      if (!current) return;
      if (!Array.isArray(result) || !result.every(isInstalledOntology)) throw new Error("La lista de ontologías instaladas no es válida.");
      for (const ontology of result) for (const collection of ontology.collections) void loadPage(ontology, collection, 0, false, scope);
    }).catch((failure) => { if (current) setError(errorText(failure)); }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; generation.current++; editorGeneration.current++; attachGeneration.current++; };
  }, [host, recordingId, loadPage]);

  const loadEndpoint = useCallback(async (ontology: InstalledOntology, table: string, page = 0, scope = editorGeneration.current) => {
    const collection = ontology.collections.find((candidate) => candidate.table === table);
    if (!collection || scope !== editorGeneration.current) return;
    setEndpoints((current) => ({ ...current, [table]: { records: page ? current[table]?.records ?? [] : [], page, hasMore: false, loading: true, error: null } }));
    try {
      const result = await host<unknown>("knowledge_records", { id: ontology.id, table, page });
      if (scope !== editorGeneration.current) return;
      if (!isRecordPage(result)) throw new Error("La página de registros no es válida.");
      setEndpoints((current) => ({ ...current, [table]: { records: page ? [...(current[table]?.records ?? []), ...result.records] : result.records, page: result.page, hasMore: result.hasMore, loading: false, error: null } }));
    } catch (failure) {
      if (scope !== editorGeneration.current) return;
      setEndpoints((current) => ({ ...current, [table]: { records: current[table]?.records ?? [], page: current[table]?.page ?? page, hasMore: current[table]?.hasMore ?? false, loading: false, error: errorText(failure) } }));
    }
  }, [host]);

  const openEditor = (key: string, record: KnowledgeRecord | null) => {
    const group = groups[key];
    if (!group || (!group.collection.fields.length && !group.collection.relation)) return;
    const raw: Record<string, string | boolean> = {};
    for (const field of group.collection.fields) raw[field.key] = field.type === "boolean" ? record?.values[field.key] === true : fieldInputText(field, record?.values[field.key]);
    if (group.collection.relation) for (const endpoint of ["in", "out"]) raw[endpoint] = fieldText(record?.values[endpoint]);
    const scope = ++editorGeneration.current;
    setEndpoints({});
    setEditor({ groupKey: key, record, raw, error: null, busy: false });
    if (group.collection.relation) for (const table of new Set([group.collection.relation.from, group.collection.relation.to])) void loadEndpoint(group.ontology, table, 0, scope);
  };

  const loadAttach = async (ontology: InstalledOntology, table: string, page = 0, scope = attachGeneration.current) => {
    if (scope !== attachGeneration.current) return;
    setAttach((current) => current ? { ...current, records: page ? current.records : [], page, hasMore: false, loading: true, error: null } : null);
    try {
      const result = await host<unknown>("knowledge_records", { id: ontology.id, table, page });
      if (scope !== attachGeneration.current) return;
      if (!isRecordPage(result)) throw new Error("La página de registros no es válida.");
      setAttach((current) => current ? { ...current, records: page ? [...current.records, ...result.records] : result.records, page: result.page, hasMore: result.hasMore, loading: false, error: null } : null);
    } catch (failure) {
      if (scope !== attachGeneration.current) return;
      setAttach((current) => current ? { ...current, loading: false, error: errorText(failure) } : null);
    }
  };

  const openAttach = (key: string) => {
    const group = groups[key];
    if (!group || !versionId) return;
    const scope = ++attachGeneration.current;
    setAttach({ groupKey: key, recordId: "", records: [], page: 0, hasMore: false, loading: true, busy: false, error: null });
    void loadAttach(group.ontology, group.collection.table, 0, scope);
  };

  const saveAttach = async () => {
    if (!attach || !versionId || !attach.recordId) return;
    const group = groups[attach.groupKey];
    if (!group) return;
    setAttach({ ...attach, busy: true, error: null });
    try {
      await host("knowledge_attach", { id: group.ontology.id, expectedVersion: group.ontology.version, recordId: attach.recordId, recordingId, versionId });
      setAttach(null);
      attachGeneration.current++;
      await loadPage(group.ontology, group.collection);
    } catch (failure) { setAttach((current) => current ? { ...current, busy: false, error: errorText(failure) } : null); }
  };

  const save = async () => {
    if (!editor) return;
    const group = groups[editor.groupKey];
    if (!group) return;
    try {
      const values = editedFields(group.collection, editor.raw, editor.record?.values);
      if (group.collection.relation) for (const endpoint of ["in", "out"]) {
        const table = endpoint === "in" ? group.collection.relation.from : group.collection.relation.to;
        if (!group.ontology.collections.some((collection) => collection.table === table)) throw new Error(`La colección «${table}» no está declarada en esta ontología.`);
        const value = String(editor.raw[endpoint] ?? "").trim();
        if (!value) throw new Error(`«${endpoint}» es obligatorio.`);
        values[endpoint] = value;
      }
      setEditor({ ...editor, busy: true, error: null });
      await host("knowledge_save", { id: group.ontology.id, table: group.collection.table, ...(editor.record ? { recordId: editor.record.id, expectedRev: editor.record.rev } : {}), values, recordingId, ...(versionId ? { versionId } : {}), expectedVersion: group.ontology.version });
      setEditor(null);
      await loadPage(group.ontology, group.collection);
    } catch (failure) { setEditor((current) => current ? { ...current, busy: false, error: errorText(failure) } : null); }
  };

  const unlink = async () => {
    if (!editor?.record) return;
    const group = groups[editor.groupKey];
    if (!group || !await confirmDestructive("¿Desvincular este registro?", "El registro se conserva para las demás notas.", "Desvincular")) return;
    setEditor({ ...editor, busy: true, error: null });
    try {
      await host("knowledge_unlink", { id: group.ontology.id, recordId: editor.record.id, recordingId, expectedVersion: group.ontology.version });
      setEditor(null);
      await loadPage(group.ontology, group.collection);
    } catch (failure) { setEditor((current) => current ? { ...current, busy: false, error: errorText(failure) } : null); }
  };

  const entries = Object.entries(groups);
  const hasRecords = entries.some(([, group]) => group.records.length);
  const selected = editor && groups[editor.groupKey];

  return <section className="detail-section knowledge-card"><div className="knowledge-card-head"><h2 className="note-section-title"><ListTree size={15} />Conocimiento</h2></div>
    {error && <div className="knowledge-error" role="alert">No se pudieron cargar las ontologías: {error}</div>}
    {loading && <div className="knowledge-loading"><Spinner /> Cargando conocimiento…</div>}
    {!loading && !error && !entries.length && <p className="knowledge-card-empty">No hay ontologías instaladas. Se instalan desde Recetas.</p>}
    {!loading && entries.length > 0 && !hasRecords && <p className="knowledge-card-empty">Esta nota aún no tiene registros relacionados.</p>}
    {entries.map(([key, group]) => <div className="knowledge-group" key={key}><div className="knowledge-group-title"><span><strong>{group.collection.label}</strong> · {group.ontology.name}</span><div className="knowledge-group-actions"><Button small disabled={!versionId} onClick={() => openAttach(key)}>Vincular existente…</Button>{(group.collection.fields.length > 0 || group.collection.relation) && <Button small icon={Plus} onClick={() => openEditor(key, null)}>Añadir</Button>}</div></div>
      {group.error && <div className="knowledge-error" role="alert">{group.error} <button type="button" className="knowledge-row-action" onClick={() => void loadPage(group.ontology, group.collection)}>Reintentar</button></div>}
      {group.records.map((record) => <div className="knowledge-record-row" key={record.id}><span className="selectable">{recordTitle(group.collection, record.values)}</span><button type="button" className="knowledge-row-action" onClick={() => openEditor(key, record)}>Editar</button></div>)}
      {group.loading && <div className="knowledge-loading"><Spinner /> Cargando…</div>}
      {group.hasMore && !group.loading && <div className="knowledge-record-row"><Button small onClick={() => void loadPage(group.ontology, group.collection, group.page + 1, true)}>Mostrar más</Button></div>}
    </div>)}
    {editor && selected && <Sheet onCancel={() => !editor.busy && setEditor(null)}><div className="knowledge-sheet"><h3>{editor.record ? "Editar" : "Nuevo registro"} · {selected.collection.label}</h3>{editor.record && <p className="font-caption secondary knowledge-shared-note">Los cambios de este registro también se verán en otras notas que lo tengan vinculado.</p>}
      {selected.collection.fields.map((field) => <label className={`knowledge-field ${field.type === "boolean" ? "knowledge-field-boolean" : ""}`} key={field.key}>{field.label}{field.required ? " *" : ""}{field.type === "boolean" ? <input type="checkbox" checked={editor.raw[field.key] === true} disabled={editor.busy} onChange={(event) => setEditor({ ...editor, raw: { ...editor.raw, [field.key]: event.target.checked } })} /> : field.type === "json" ? <textarea value={String(editor.raw[field.key] ?? "")} disabled={editor.busy} onChange={(event) => setEditor({ ...editor, raw: { ...editor.raw, [field.key]: event.target.value } })} /> : <input type={field.type === "date" ? "date" : "text"} value={String(editor.raw[field.key] ?? "")} disabled={editor.busy} onChange={(event) => setEditor({ ...editor, raw: { ...editor.raw, [field.key]: event.target.value } })} />}</label>)}
      {selected.collection.relation && ([{ key: "in", table: selected.collection.relation.from, label: "Origen" }, { key: "out", table: selected.collection.relation.to, label: "Destino" }]).map((endpoint) => {
        const state = endpoints[endpoint.table];
        const collection = selected.ontology.collections.find((candidate) => candidate.table === endpoint.table);
        const chosen = String(editor.raw[endpoint.key] ?? "");
        return <div className="knowledge-endpoint" key={endpoint.key}><label className="knowledge-field">{endpoint.label} · {collection?.label ?? endpoint.table} *<select value={chosen} disabled={editor.busy || !collection} onChange={(event) => setEditor({ ...editor, raw: { ...editor.raw, [endpoint.key]: event.target.value } })}><option value="">Selecciona un registro…</option>{chosen && !state?.records.some((record) => record.id === chosen) && <option value={chosen}>{chosen}</option>}{state?.records.map((record) => <option value={record.id} key={record.id}>{recordTitle(collection ?? selected.collection, record.values)}</option>)}</select></label>{!collection && <div className="knowledge-error" role="alert">La colección «{endpoint.table}» no está declarada en esta ontología.</div>}{state?.loading && <span className="font-caption secondary">Cargando registros…</span>}{state?.error && <div className="knowledge-error" role="alert">{state.error} <button type="button" className="knowledge-row-action" onClick={() => void loadEndpoint(selected.ontology, endpoint.table)}>Reintentar</button></div>}{state?.hasMore && !state.loading && <Button small onClick={() => void loadEndpoint(selected.ontology, endpoint.table, state.page + 1)}>Mostrar más</Button>}</div>;
      })}
      {editor.error && <div className="knowledge-error" role="alert">{editor.error}</div>}
      <div className="knowledge-actions">{editor.record && <button type="button" className="knowledge-row-action destructive" disabled={editor.busy} onClick={() => void unlink()}>Desvincular…</button>}<Button small disabled={editor.busy} onClick={() => setEditor(null)}>Cancelar</Button><Button small prominent disabled={editor.busy} onClick={() => void save()}>{editor.busy ? "Guardando…" : "Guardar"}</Button></div>
    </div></Sheet>}
    {attach && groups[attach.groupKey] && <Sheet onCancel={() => { if (!attach.busy) { setAttach(null); attachGeneration.current++; } }}><div className="knowledge-sheet"><h3>Vincular registro · {groups[attach.groupKey].collection.label}</h3><p className="font-caption secondary knowledge-shared-note">El registro conservará sus vínculos con las otras notas.</p><label className="knowledge-field">Registro<select value={attach.recordId} disabled={attach.busy || attach.loading && !attach.records.length} onChange={(event) => setAttach({ ...attach, recordId: event.target.value })}><option value="">Selecciona un registro…</option>{attach.records.map((record) => <option key={record.id} value={record.id}>{recordTitle(groups[attach.groupKey].collection, record.values)}</option>)}</select></label>{attach.loading && <div className="knowledge-loading"><Spinner /> Cargando registros…</div>}{attach.error && <div className="knowledge-error" role="alert">{attach.error} <button type="button" className="knowledge-row-action" onClick={() => void loadAttach(groups[attach.groupKey].ontology, groups[attach.groupKey].collection.table, attach.page)}>Reintentar</button></div>}{attach.hasMore && !attach.loading && <Button small onClick={() => void loadAttach(groups[attach.groupKey].ontology, groups[attach.groupKey].collection.table, attach.page + 1)}>Mostrar más</Button>}<div className="knowledge-actions"><Button small disabled={attach.busy} onClick={() => { setAttach(null); attachGeneration.current++; }}>Cancelar</Button><Button small prominent disabled={attach.busy || !attach.recordId} onClick={() => void saveAttach()}>{attach.busy ? "Vinculando…" : "Vincular"}</Button></div></div></Sheet>}
  </section>;
}
