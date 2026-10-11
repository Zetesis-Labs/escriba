import { BookOpen, Download, RotateCw } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { call } from "../api";
import { Button, Segmented, Spinner } from "../mac/controls";
import { errorText } from "../mac/native";
import { candidateStatus, extensionOntologies, isDefinition, isInstalledOntology, type InstalledOntology, type KnowledgeCollection, type OntologyDefinition, type RuntimeHost } from "./model";
import "./knowledge.css";
import { GraphExplorer } from "./GraphExplorer";

const fieldTypeLabel: Record<string, string> = { text: "Texto", number: "Número", boolean: "Sí / no", date: "Fecha", json: "JSON", reference: "Referencia" };

function CollectionDetails({ collection }: { collection: KnowledgeCollection }) {
  return <details className="knowledge-collection"><summary><span>{collection.label}</span><code>{collection.table}</code></summary><div className="knowledge-collection-detail">
    {collection.relation && <p className="knowledge-relation">Relación: <code>{collection.relation.from}</code> → <code>{collection.relation.to}</code></p>}
    {collection.fields.length ? <dl>{collection.fields.map((field) => <div key={field.key}><dt>{field.label}<code>{field.key}</code></dt><dd>{fieldTypeLabel[field.type]}{field.required ? " · Obligatorio" : ""}{field.reference && <> · {field.reference.ontologyId}/{field.reference.table}</>}</dd></div>)}</dl> : <p className="font-caption secondary">Sin campos declarados.</p>}
  </div></details>;
}

export function OntologySummary({ ontology, base = false }: { ontology: OntologyDefinition; base?: boolean }) {
  return <div className={`knowledge-ontology-summary${base ? " knowledge-ontology-base" : ""}`}><div className="knowledge-ontology-row"><BookOpen size={16} strokeWidth={1.7} /><div><strong>{ontology.name}</strong><span className="font-caption secondary">{base ? "Incluida y mantenida por Escriba" : ontology.collections.map((collection) => collection.label).join(" · ") || "Sin colecciones"}</span></div><span className="font-caption secondary">v{ontology.version}</span></div><div className="knowledge-collections">{ontology.collections.map((collection) => <CollectionDetails key={collection.table} collection={collection} />)}</div></div>;
}

export function OntologiesPanel({ projectDefinitions, host = call }: { projectDefinitions?: OntologyDefinition[]; host?: RuntimeHost }) {
  const [installed, setInstalled] = useState<InstalledOntology[]>([]);
  const [candidates, setCandidates] = useState<OntologyDefinition[]>(projectDefinitions ?? []);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const requestGeneration = useRef(0);
  const [mode, setMode] = useState<"schema" | "data" | "catalog">("schema");

  const load = useCallback(async () => {
    const generation = ++requestGeneration.current;
    setLoading(true);
    setError(null);
    try {
      const installedResult = await host<unknown>("knowledge_list");
      if (generation !== requestGeneration.current) return;
      if (!Array.isArray(installedResult) || !installedResult.every(isInstalledOntology)) throw new Error("La lista de ontologías instaladas no es válida.");
      setInstalled(installedResult);
      if (projectDefinitions) setCandidates(projectDefinitions);
      else {
        const candidateResult = await host<unknown>("knowledge_candidates");
        if (generation !== requestGeneration.current) return;
        if (!Array.isArray(candidateResult) || !candidateResult.every(isDefinition)) throw new Error("Las ontologías del proyecto no son válidas.");
        setCandidates(candidateResult);
      }
    } catch (failure) { if (generation === requestGeneration.current) setError(errorText(failure)); }
    finally { if (generation === requestGeneration.current) setLoading(false); }
  }, [host, projectDefinitions]);

  useEffect(() => { void load(); return () => { requestGeneration.current++; }; }, [load]);

  const install = async (definition: OntologyDefinition) => {
    setBusy(definition.id);
    setError(null);
    try {
      await host("knowledge_install", { definition });
      await load();
    } catch (failure) { setError(errorText(failure)); }
    finally { setBusy(null); }
  };

  const base = installed.filter((ontology) => ontology.builtIn === true);
  const extensions = extensionOntologies(installed);
  const extensionCandidates = extensionOntologies(candidates);
  const pending = extensionCandidates.map((definition) => ({ definition, status: candidateStatus(definition, extensions) })).filter(({ status }) => status === "install" || status === "update");
  const older = extensionCandidates.filter((definition) => candidateStatus(definition, extensions) === "older");
  const conflicts = extensionCandidates.filter((definition) => candidateStatus(definition, extensions) === "conflict");

  return <div className="ontology-workspace">
    <div className="ontology-mode-bar"><Segmented value={mode} onChange={setMode} options={[{ value: "schema", label: "Estructura" }, { value: "data", label: "Datos" }, { value: "catalog", label: "Instalación" }]} /><p>{mode === "schema" ? "Entidades y relaciones de la base y sus extensiones." : mode === "data" ? "Explora los registros y abre sus conexiones." : "Las ontologías permanecen al cambiar de proyecto."}</p><Button small icon={RotateCw} onClick={() => void load()} disabled={loading || !!busy} title="Actualizar ontologías" /></div>
    {error && <div className="knowledge-error" role="alert">{error}</div>}
    {loading ? <div className="knowledge-loading"><Spinner /> Cargando ontologías…</div> : mode !== "catalog" ? <GraphExplorer key={mode} mode={mode} ontologies={installed} host={host} /> : <div className="ontology-catalog"><div className="knowledge-ontologies">
    <div className="knowledge-heading"><div><h2>Ontologías</h2><p className="font-caption secondary">Estructuras instaladas en esta biblioteca. Actualizar el proyecto no las cambia.</p></div><Button small icon={RotateCw} onClick={() => void load()} disabled={loading || !!busy}>Actualizar lista</Button></div>
      <section className="knowledge-section"><h3>Base de Escriba</h3>
        {base.length ? base.map((ontology) => <OntologySummary key={ontology.id} ontology={ontology} base />) : <p className="font-caption secondary">La base de Escriba no está disponible en este momento.</p>}
      </section>
      <section className="knowledge-section"><h3>Extensiones instaladas</h3>
        {extensions.length ? extensions.map((ontology) => <OntologySummary key={ontology.id} ontology={ontology} />) : <p className="font-caption secondary">Todavía no hay extensiones instaladas.</p>}
      </section>
      <section className="knowledge-section"><h3>Extensiones del proyecto</h3>
        {pending.length ? pending.map(({ definition, status }) => <div className="knowledge-ontology-row" key={definition.id}><Download size={16} strokeWidth={1.7} /><div><strong>{definition.name}</strong><span className="font-caption secondary">{status === "update" ? `Actualizar a v${definition.version}` : `Instalar v${definition.version}`} · {definition.collections.map((collection) => collection.label).join(" · ")}</span></div><Button small disabled={!!busy} onClick={() => void install(definition)}>{busy === definition.id ? "Aplicando…" : status === "update" ? "Actualizar" : "Instalar"}</Button></div>) : <p className="font-caption secondary">No hay instalaciones ni actualizaciones pendientes.</p>}
        {older.map((definition) => <p className="font-caption warning" key={definition.id}>El proyecto ofrece «{definition.name}» v{definition.version}, anterior a la instalada. Se conserva la versión instalada.</p>)}
        {conflicts.map((definition) => <p className="font-caption warning" role="alert" key={definition.id}>«{definition.name}» v{definition.version} tiene una definición distinta de la versión instalada. Cambia el número de versión del proyecto antes de actualizar.</p>)}
      </section>
    </div></div>}
  </div>;
}
