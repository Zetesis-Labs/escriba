import { Plus, Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { knowledge } from "../api";
import { conditionText, conditionValue, defaultCondition, filterFields, filterOperators, filterRecordLabel, type FilterCondition, type FilterOperator, type LibraryFilter, type SavedLibraryFilter } from "../core/libraryFilters";
import type { KnowledgeCollection, OntologyDefinition } from "../knowledge/model";
import type { GraphPage } from "../knowledge/graphTypes";
import { Button, Segmented, Sheet, Spinner } from "../mac/controls";
import { errorText } from "../mac/native";
import type { LibraryFiltersController } from "./useLibraryFilters";
import "./libraryFilters.css";

type DraftCondition = Omit<FilterCondition, "value"> & { raw: string };
const draftFrom = (condition: FilterCondition, catalog: OntologyDefinition[]): DraftCondition => {
  const collection = catalog.find((item) => item.id === condition.ontologyId)?.collections.find((item) => item.table === condition.table);
  const field = collection && filterFields(collection, condition.ontologyId).find((item) => item.key === condition.field);
  return { ...condition, raw: conditionText(field, condition.value) };
};
const defaultField = (collection: KnowledgeCollection, ontologyId: string) => (collection.fields.find((field) => field.key === collection.titleField) ?? collection.fields.find((field) => field.key === "name") ?? collection.fields[0] ?? filterFields(collection, ontologyId)[0]).key;
const initialDraft = (catalog: OntologyDefinition[]): DraftCondition[] => { const first = defaultCondition(catalog); return first ? [draftFrom(first, catalog)] : []; };

export function LibraryFilters({ controller, editing, onClose }: { controller: LibraryFiltersController; editing: SavedLibraryFilter | null; onClose: () => void }) {
  const { catalog, catalogError, catalogLoading } = controller;
  const active = editing?.filter ?? controller.result?.filter;
  const [mode, setMode] = useState<"visual" | "surrealql">(active?.kind ?? "visual");
  const [match, setMatch] = useState<"all" | "any">(active?.kind === "visual" ? active.match : "all");
  const [conditions, setConditions] = useState<DraftCondition[]>(active?.kind === "visual" && catalog.length ? active.conditions.map((item) => draftFrom(item, catalog)) : []);
  const [ontologyId, setOntologyId] = useState(active?.kind === "surrealql" ? active.ontologyId : "");
  const [sql, setSql] = useState(active?.kind === "surrealql" ? active.sql : "");
  const [name, setName] = useState(editing?.name ?? controller.result?.name ?? "");
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { void controller.loadCatalog(); }, [controller.loadCatalog]);
  useEffect(() => {
    if (!catalog.length) return;
    setConditions((current) => current.length ? current : active?.kind === "visual" ? active.conditions.map((item) => draftFrom(item, catalog)) : initialDraft(catalog));
    setOntologyId((current) => current || catalog[0].id);
  }, [catalog, active]);

  const update = (index: number, patch: Partial<DraftCondition>) => setConditions((current) => current.map((item, position) => position === index ? { ...item, ...patch } : item));
  const add = () => { const next = initialDraft(catalog)[0]; if (next) setConditions((current) => [...current, next]); };
  const build = (): LibraryFilter => {
    if (mode === "surrealql") {
      if (!ontologyId || !sql.trim()) throw new Error("Elige una ontología y escribe la consulta.");
      return { kind: "surrealql", ontologyId, sql: sql.trim() };
    }
    if (!conditions.length) throw new Error("Añade una condición.");
    return { kind: "visual", match, conditions: conditions.map(({ raw, ...condition }) => {
      const collection = catalog.find((item) => item.id === condition.ontologyId)?.collections.find((item) => item.table === condition.table);
      const field = collection && filterFields(collection, condition.ontologyId).find((item) => item.key === condition.field);
      if (!field) throw new Error("El campo elegido ya no existe en la ontología.");
      const value = conditionValue(field, condition.operator, raw);
      return value === undefined ? condition : { ...condition, value };
    }) };
  };
  const apply = async () => {
    try { setProblem(null); const filter = build(); onClose(); await controller.apply(filter); }
    catch (failure) { setProblem(errorText(failure)); }
  };
  const save = async () => {
    try {
      setProblem(null);
      const filter = build();
      if (!name.trim()) throw new Error("Ponle un nombre al filtro.");
      setBusy(true);
      const stored = await controller.save({ id: editing?.id, name: name.trim(), filter });
      onClose();
      controller.selectSaved(stored);
    } catch (failure) { setProblem(errorText(failure)); }
    finally { setBusy(false); }
  };
  const remove = async () => {
    if (!editing) return;
    try { setBusy(true); await controller.remove(editing.id); onClose(); }
    catch (failure) { setProblem(errorText(failure)); }
    finally { setBusy(false); }
  };

  return <Sheet onCancel={onClose}>
    <div className="library-filter-sheet">
      <div className="library-filter-heading"><div><h2 className="font-headline">{editing ? "Editar filtro" : "Filtrar Biblioteca"}</h2><p className="font-caption secondary">Selecciona notas por el conocimiento de su versión vigente.</p></div></div>
      <Segmented value={mode} onChange={setMode} options={[{ value: "visual", label: "Visual" }, { value: "surrealql", label: "SurrealQL" }]} />
      {catalogLoading && !catalog.length ? <div className="library-filter-state"><Spinner /> Leyendo ontologías…</div> : catalogError ? <div className="library-filter-error" role="alert">{catalogError}</div> : mode === "visual" ? <div className="library-filter-body">
        <div className="library-filter-match"><span>Mostrar notas que cumplen</span><Segmented value={match} onChange={setMatch} options={[{ value: "all", label: "Todas" }, { value: "any", label: "Cualquiera" }]} /></div>
        {conditions.map((condition, index) => <ConditionEditor key={index} condition={condition} catalog={catalog} onChange={(patch) => update(index, patch)} onRemove={() => setConditions((current) => current.filter((_, position) => position !== index))} />)}
        <Button small icon={Plus} onClick={add} disabled={!catalog.length}>Añadir condición</Button>
        {!catalog.some((item) => item.collections.length) && <p className="font-caption secondary">No hay entidades instaladas.</p>}
      </div> : <div className="library-filter-body">
        <label className="library-filter-label">Ontología
          <select value={ontologyId} onChange={(event) => setOntologyId(event.target.value)}>{catalog.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select>
        </label>
        <label className="library-filter-label">Consulta SurrealQL
          <textarea className="library-filter-sql selectable" value={sql} onChange={(event) => setSql(event.target.value)} rows={7} placeholder="SELECT id FROM entidad WHERE campo = 'valor'" spellCheck={false} />
        </label>
        <p className="font-caption secondary">La consulta debe devolver identidades de entidades. Escriba buscará sus notas relacionadas.</p>
      </div>}
      <label className="library-filter-label">Nombre para guardar
        <input value={name} onChange={(event) => setName(event.target.value)} placeholder="Por ejemplo, acuerdos pendientes" />
      </label>
      {problem && <div className="library-filter-error" role="alert">{problem}</div>}
      <div className="sheet-actions library-filter-actions">
        {editing && <Button icon={Trash2} onClick={() => void remove()} disabled={busy} title="Eliminar el filtro guardado">Eliminar</Button>}
        <span className="library-filter-spacer" />
        <Button onClick={onClose}>Cancelar</Button>
        <Button onClick={() => void save()} disabled={busy || !catalog.length}>Guardar</Button>
        <Button prominent onClick={() => void apply()} disabled={busy || !catalog.length}>Aplicar</Button>
      </div>
    </div>
  </Sheet>;
}

function ConditionEditor({ condition, catalog, onChange, onRemove }: { condition: DraftCondition; catalog: OntologyDefinition[]; onChange: (patch: Partial<DraftCondition>) => void; onRemove: () => void }) {
  const ontology = catalog.find((item) => item.id === condition.ontologyId) ?? catalog[0];
  const collection = ontology?.collections.find((item) => item.table === condition.table) ?? ontology?.collections[0];
  const fields = collection ? filterFields(collection, ontology?.id ?? "") : [];
  const field = fields.find((item) => item.key === condition.field) ?? fields[0];
  const operators = field ? filterOperators(field) : [];
  const noValue = condition.operator === "empty" || condition.operator === "notEmpty";
  const setCollection = (item: KnowledgeCollection) => onChange({ table: item.table, field: defaultField(item, ontology?.id ?? ""), operator: "eq", raw: filterFields(item, ontology?.id ?? "").find((field) => field.key === defaultField(item, ontology?.id ?? ""))?.type === "boolean" ? "true" : "" });
  return <div className="library-filter-condition">
    <div className="library-filter-condition-top">
      <select aria-label="Ontología" value={ontology?.id ?? ""} onChange={(event) => {
        const next = catalog.find((item) => item.id === event.target.value);
        const item = next?.collections[0];
        if (item) onChange({ ontologyId: next.id, table: item.table, field: defaultField(item, next.id), operator: "eq", raw: filterFields(item, next.id).find((field) => field.key === defaultField(item, next.id))?.type === "boolean" ? "true" : "" });
      }}>{catalog.filter((item) => item.collections.length).map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select>
      <select aria-label="Entidad" value={collection?.table ?? ""} onChange={(event) => { const item = ontology?.collections.find((candidate) => candidate.table === event.target.value); if (item) setCollection(item); }}>{ontology?.collections.map((item) => <option value={item.table} key={item.table}>{item.label}</option>)}</select>
      <button type="button" className="library-filter-remove" aria-label="Quitar condición" onClick={onRemove}><Trash2 size={14} /></button>
    </div>
    <div className="library-filter-condition-bottom">
      <select aria-label="Campo" value={field?.key ?? ""} onChange={(event) => onChange({ field: event.target.value, operator: "eq", raw: fields.find((item) => item.key === event.target.value)?.type === "boolean" ? "true" : "" })}>{fields.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select>
      <select aria-label="Operador" value={condition.operator} onChange={(event) => onChange({ operator: event.target.value as FilterOperator })}>{operators.map((item) => <option value={item.value} key={item.value}>{item.label}</option>)}</select>
      {!noValue && (field && (field.recordTarget) ? <RecordChoice key={`${condition.ontologyId}:${condition.table}:${condition.field}`} field={field} condition={condition} collection={collection} ontology={ontology} catalog={catalog} onChange={(raw) => onChange({ raw })} /> : field?.type === "boolean" ? <select aria-label="Valor" value={condition.raw || "true"} onChange={(event) => onChange({ raw: event.target.value })}><option value="true">Sí</option><option value="false">No</option></select> : <input aria-label="Valor" type={field?.type === "number" ? "number" : field?.type === "date" ? "date" : "text"} value={condition.raw} onChange={(event) => onChange({ raw: event.target.value })} placeholder="Valor" />)}
      {!noValue && field?.type === "date" && <span className="library-filter-utc">UTC</span>}
    </div>
  </div>;
}

function RecordChoice({ field, condition, collection, ontology, catalog, onChange }: { field: ReturnType<typeof filterFields>[number]; condition: DraftCondition; collection: KnowledgeCollection | undefined; ontology: OntologyDefinition | undefined; catalog: OntologyDefinition[]; onChange: (raw: string) => void }) {
  const targetOntology = catalog.find((item) => item.id === (field.recordTarget?.ontologyId ?? ontology?.id));
  const targetTable = field.recordTarget?.table;
  const target = targetOntology?.collections.find((item) => item.table === targetTable);
  const [records, setRecords] = useState<{ id: string; label: string }[]>([]);
  const [page, setPage] = useState(0);
  const [more, setMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const generation = useRef(0);
  const [selectedPreview, setSelectedPreview] = useState<{ id: string; label?: string; error?: string; loading: boolean } | null>(null);
  const selectedId = field.recordTarget?.value === "reference" ? (() => { try { const value = JSON.parse(condition.raw) as { id?: string }; return value.id ?? ""; } catch { return ""; } })() : condition.raw;
  const selectedOnPage = records.some((record) => record.id === selectedId);
  const load = async (nextPage: number) => {
    if (!targetOntology || !targetTable) return;
    const request = generation.current;
    setLoading(true); setProblem(null);
    try {
      const result = await knowledge("knowledge_graph_roots", { ontologyId: targetOntology.id, table: targetTable, page: nextPage });
      if (generation.current !== request) return;
      setRecords((current) => dedupeChoices([...current, ...pageChoices(result, Boolean(target?.relation))]));
      setPage(result.page); setMore(result.hasMore);
    } catch (failure) { if (generation.current === request) setProblem(errorText(failure)); }
    finally { if (generation.current === request) setLoading(false); }
  };
  useEffect(() => {
    let alive = true;
    const request = ++generation.current;
    setRecords([]); setPage(0); setMore(false); setLoading(true); setProblem(null);
    if (!targetOntology || !targetTable) { setLoading(false); return; }
    void knowledge("knowledge_graph_roots", { ontologyId: targetOntology.id, table: targetTable, page: 0 }).then((result) => {
      if (!alive || generation.current !== request) return;
      setRecords(pageChoices(result, Boolean(target?.relation))); setMore(result.hasMore); setPage(result.page);
    }).catch((failure) => { if (alive && generation.current === request) setProblem(errorText(failure)); }).finally(() => { if (alive && generation.current === request) setLoading(false); });
    return () => { alive = false; generation.current++; };
  }, [targetOntology?.id, targetTable]);
  useEffect(() => {
    if (!selectedId || selectedOnPage || loading || !targetOntology || !target) { setSelectedPreview(null); return; }
    let alive = true;
    setSelectedPreview({ id: selectedId, loading: true });
    const detail = async (recordId: string) => (await knowledge("knowledge_graph_detail", { ontologyId: targetOntology.id, recordId })).values;
    void detail(selectedId).then((values) => filterRecordLabel(targetOntology, target, values, detail)).then((label) => {
      if (alive) setSelectedPreview({ id: selectedId, label, loading: false });
    }).catch((failure) => { if (alive) setSelectedPreview({ id: selectedId, error: errorText(failure), loading: false }); });
    return () => { alive = false; };
  }, [selectedId, selectedOnPage, loading, targetOntology?.id, targetTable]);
  const preview = selectedPreview?.id === selectedId ? selectedPreview : null;
  return <div className="library-filter-record-choice"><select aria-label="Registro" value={selectedId} onChange={(event) => onChange(field.recordTarget?.value === "reference" && event.target.value ? JSON.stringify({ ontologyId: "escriba", table: targetTable, id: event.target.value }) : event.target.value)}>
    <option value="">Selecciona un registro…</option>
    {selectedId && !selectedOnPage && <option value={selectedId}>{preview?.loading ? "Leyendo registro…" : preview?.label ?? (preview?.error ? "Registro no disponible" : "Leyendo registro…")}</option>}
    {records.map((record) => <option value={record.id} key={record.id}>{record.label}</option>)}
  </select>{loading && <Spinner />}{(problem || preview?.error) && <span className="library-filter-error" role="alert">{problem ?? preview?.error}</span>}{more && !loading && <Button small onClick={() => void load(page + 1)}>Más</Button>}</div>;
}

function pageChoices(page: GraphPage, relation: boolean): { id: string; label: string }[] {
  if (!relation) return page.nodes.map((node) => ({ id: node.recordId, label: node.label }));
  const names = new Map(page.nodes.map((node) => [node.key, node.label]));
  return page.edges.filter((edge) => edge.kind === "relation" && edge.recordId).map((edge) => ({
    id: edge.recordId!,
    label: `${names.get(edge.source) ?? edge.source} → ${names.get(edge.target) ?? edge.target}`,
  }));
}

function dedupeChoices(choices: { id: string; label: string }[]): { id: string; label: string }[] {
  return [...new Map(choices.map((choice) => [choice.id, choice])).values()];
}
