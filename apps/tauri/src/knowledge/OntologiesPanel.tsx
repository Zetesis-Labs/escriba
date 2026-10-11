import { BookOpen, Download, RotateCw } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { call } from "../api";
import { Button, Spinner } from "../mac/controls";
import { errorText } from "../mac/native";
import { candidateStatus, isDefinition, isInstalledOntology, type InstalledOntology, type OntologyDefinition, type RuntimeHost } from "./model";
import "./knowledge.css";

export function OntologiesPanel({ projectDefinitions, host = call }: { projectDefinitions?: OntologyDefinition[]; host?: RuntimeHost }) {
  const [installed, setInstalled] = useState<InstalledOntology[]>([]);
  const [candidates, setCandidates] = useState<OntologyDefinition[]>(projectDefinitions ?? []);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const requestGeneration = useRef(0);

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

  const pending = candidates.map((definition) => ({ definition, status: candidateStatus(definition, installed) })).filter(({ status }) => status === "install" || status === "update");
  const older = candidates.filter((definition) => candidateStatus(definition, installed) === "older");
  const conflicts = candidates.filter((definition) => candidateStatus(definition, installed) === "conflict");

  return <div className="knowledge-ontologies">
    <div className="knowledge-heading"><div><h2>Ontologías</h2><p className="font-caption secondary">Estructuras instaladas en esta biblioteca. Actualizar el proyecto no las cambia.</p></div><Button small icon={RotateCw} onClick={() => void load()} disabled={loading || !!busy}>Actualizar lista</Button></div>
    {error && <div className="knowledge-error" role="alert">{error}</div>}
    {loading ? <div className="knowledge-loading"><Spinner /> Cargando ontologías…</div> : <>
      <section className="knowledge-section"><h3>Instaladas</h3>
        {installed.length ? installed.map((ontology) => <div className="knowledge-ontology-row" key={ontology.id}><BookOpen size={16} strokeWidth={1.7} /><div><strong>{ontology.name}</strong><span className="font-caption secondary">{ontology.collections.map((collection) => collection.label).join(" · ") || "Sin colecciones"}</span></div><span className="font-caption secondary">v{ontology.version}</span></div>) : <p className="font-caption secondary">Todavía no hay ontologías instaladas.</p>}
      </section>
      <section className="knowledge-section"><h3>Pendientes del proyecto</h3>
        {pending.length ? pending.map(({ definition, status }) => <div className="knowledge-ontology-row" key={definition.id}><Download size={16} strokeWidth={1.7} /><div><strong>{definition.name}</strong><span className="font-caption secondary">{status === "update" ? `Actualizar a v${definition.version}` : `Instalar v${definition.version}`} · {definition.collections.map((collection) => collection.label).join(" · ")}</span></div><Button small disabled={!!busy} onClick={() => void install(definition)}>{busy === definition.id ? "Aplicando…" : status === "update" ? "Actualizar" : "Instalar"}</Button></div>) : <p className="font-caption secondary">No hay instalaciones ni actualizaciones pendientes.</p>}
        {older.map((definition) => <p className="font-caption warning" key={definition.id}>El proyecto ofrece «{definition.name}» v{definition.version}, anterior a la instalada. Se conserva la versión instalada.</p>)}
        {conflicts.map((definition) => <p className="font-caption warning" role="alert" key={definition.id}>«{definition.name}» v{definition.version} tiene una definición distinta de la versión instalada. Cambia el número de versión del proyecto antes de actualizar.</p>)}
      </section>
    </>}
  </div>;
}
