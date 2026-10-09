import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { AlertTriangle, BadgeCheck, Braces, ChevronRight, Minus, Plus, SlidersHorizontal, Clock, CheckCircle2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { call, desktop } from "../api";
import { Pane } from "../app/Pane";
import { recordingWhen } from "../core/presentation";
import { recipeFormLoad, recipeFormOverrides, recipeFormValues, recipeFormExport, type RecipeFormLoad } from "../core/recipeForm";
import { displayTitle } from "../library/RecordingRow";
import { formatSeconds, TraceDetail, traceOutcome, traceSeconds } from "../library/TraceCard";
import { Button, ContentUnavailable, FormRow, FormSection, InlineField, LabeledRow, ListBar, ListBarButton, PopupButton, Segmented, Spinner } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText, item, popupMenu, separator } from "../mac/native";
import { getRecipeSchema, processRecording } from "../runtime";
import type { JSONObject, JSONValue, Recipe, RecipeTrace, Recording, Snapshot } from "../types";
import { RecipeFormSections } from "./RecipeFormSections";
import "./recipes.css";

type Phase = { phase: "idle" | "building" | "ready" } | { phase: "failed"; message: string };
const withoutDerived = ({ bundleFingerprint: _fingerprint, ...recipe }: Recipe) => recipe;
const home = (path: string) => path.replace(/^\/Users\/[^/]+/, "~");

function useProjectPhase() {
  const [phase, setPhase] = useState<Phase>({ phase: "idle" });
  useEffect(() => {
    if (!desktop) return;
    let stop: (() => void) | undefined;
    void listen<Phase>("escriba://project", (event) => setPhase(event.payload)).then((unlisten) => {
      stop = unlisten;
    });
    return () => stop?.();
  }, []);
  return [phase, setPhase] as const;
}

export function RecipesPane({ data, refresh }: { data: Snapshot; refresh: () => Promise<void> }) {
  const forms = data.recipes.filter((recipe) => recipe.kind === "form");
  const codes = data.recipes.filter((recipe) => recipe.kind === "code");
  const defaultId = data.settings.defaultRecipeId;
  const [chosen, setChosen] = useState<string>(defaultId);
  const selected = data.recipes.find((recipe) => recipe.id === chosen) ?? data.recipes.find((recipe) => recipe.id === defaultId) ?? null;
  const [phase, setPhase] = useProjectPhase();

  const save = async (recipe: Recipe) => {
    try {
      await call("config_save", { collection: "recipes", item: withoutDerived(recipe) });
    } catch (failure) {
      await alertMessage("No se pudo guardar", errorText(failure));
    } finally {
      await refresh();
    }
  };
  const makeDefault = async (id: string) => {
    await call("settings_save", { settings: { defaultRecipeId: id } }).catch((failure) => alertMessage("No se pudo", errorText(failure)));
    await refresh();
  };
  const addForm = async (recipe: Partial<Recipe> = {}) => {
    const created: Recipe = { id: crypto.randomUUID(), name: "Receta nueva", kind: "form", values: {}, ...recipe };
    await save(created);
    setChosen(created.id);
  };
  const duplicate = (recipe: Recipe) => addForm({ name: `${recipe.name} (copia)`, base: recipe.base, values: recipe.values });
  const saveAsForm = (recipe: Recipe) => addForm({ name: `${recipe.name} (copia)`, base: recipe.id, values: recipe.values });
  const remove = async (recipe: Recipe) => {
    const next = forms.find((candidate) => candidate.id !== recipe.id);
    const confirmed = await confirmDestructive(
      `¿Quitar «${recipe.name}»?`,
      recipe.id === defaultId ? `Es la receta por defecto: pasará a serlo «${next?.name ?? ""}».` : "Las notas ya procesadas no cambian.",
      "Quitar",
    );
    if (!confirmed) return;
    try {
      if (recipe.id === defaultId && next) await call("settings_save", { settings: { defaultRecipeId: next.id } });
      await call("config_remove", { collection: "recipes", id: recipe.id });
      setChosen(next?.id ?? defaultId);
    } catch (failure) {
      await alertMessage("No se pudo", errorText(failure));
    } finally {
      await refresh();
    }
  };
  const chooseProject = async () => {
    const path = await open({ directory: true, title: "Usar esta carpeta" });
    if (typeof path !== "string") return;
    setPhase({ phase: "building" });
    try {
      await call("project_init", { path });
      await call("runtime_run", { operation: "rebuildProject", args: {} });
      setPhase({ phase: "ready" });
    } catch (failure) {
      setPhase({ phase: "failed", message: errorText(failure) });
    } finally {
      await refresh();
    }
  };

  const formSubtitle = (recipe: Recipe) => {
    if (!recipe.base) return "De serie · se configura aquí";
    const base = codes.find((code) => code.id === recipe.base);
    return base ? `De «${base.name}» · se configura aquí` : `Su receta «${recipe.base}» ya no está`;
  };
  const missing = !data.recipes.some((recipe) => recipe.id === defaultId) && phase.phase !== "building";
  const selectedIsForm = selected?.kind === "form";
  const canRemove = selectedIsForm && forms.length >= 2 && selected?.id !== "default";

  const row = (recipe: Recipe, subtitle: string, menu: () => ReturnType<typeof item>[]) => (
    <div
      key={recipe.id}
      role="option"
      aria-selected={recipe.id === selected?.id}
      className={`list-row recipe-row ${recipe.id === selected?.id ? "selected" : ""}`}
      onMouseDown={() => setChosen(recipe.id)}
      onContextMenu={(event) => {
        event.preventDefault();
        setChosen(recipe.id);
        void popupMenu(menu(), { x: event.clientX, y: event.clientY });
      }}
    >
      {recipe.kind === "form" ? <SlidersHorizontal size={15} strokeWidth={1.7} className="secondary" /> : <Braces size={15} strokeWidth={1.7} className="secondary" />}
      <div className="recipe-row-text">
        <div>{recipe.name}</div>
        <div className="font-caption secondary">{subtitle}</div>
      </div>
      {recipe.id === defaultId && (
        <span className="default-badge font-caption2" title="Procesa todo lo que entra">
          Por defecto
        </span>
      )}
    </div>
  );

  return (
    <Pane title="Recetas">
      <div className="list-detail">
        <div className="side-list" style={{ width: 260 }}>
          <div className="side-list-items" role="listbox" aria-label="Recetas" tabIndex={0}>
            <div className="list-section font-caption secondary">De formulario</div>
            {forms.map((recipe) =>
              row(recipe, formSubtitle(recipe), () => [
                item("Duplicar", () => void duplicate(recipe)),
                item("Usar por defecto", () => void makeDefault(recipe.id), { enabled: recipe.id !== defaultId }),
                separator,
                item("Quitar…", () => void remove(recipe), { enabled: forms.length >= 2 && recipe.id !== "default" }),
              ]),
            )}
            <div className="list-section font-caption secondary">De código</div>
            {codes.map((recipe) => row(recipe, `Código · ${recipe.id}`, () => [item("Guardar como receta de formulario", () => void saveAsForm(recipe))]))}
            <ProjectFooter path={data.settings.projectPath} phase={phase} onChoose={() => void chooseProject()} />
          </div>
          {missing && (
            <div className="font-caption warning missing-default">
              <AlertTriangle size={12} strokeWidth={2} /> La receta por defecto «{defaultId}» ya no está en el proyecto: las notas esperan hasta que elijas otra.
            </div>
          )}
          <ListBar>
            <ListBarButton icon={Plus} label="Nueva receta de formulario" onClick={() => void addForm()} />
            <ListBarButton icon={Minus} label="Quitar" onClick={() => selected && void remove(selected)} disabled={!canRemove} />
          </ListBar>
        </div>
        <div className="list-detail-divider" />
        <div className="detail-column">
          {selected ? (
            <RecipeDetail
              key={selected.id}
              recipe={selected}
              data={data}
              isDefault={selected.id === defaultId}
              onSave={save}
              onDefault={() => void makeDefault(selected.id)}
              onSaveAsForm={() => void saveAsForm(selected)}
            />
          ) : (
            <ContentUnavailable title="Sin receta elegida" icon={Braces} description="Elige una de la lista, o crea una con +." />
          )}
        </div>
      </div>
    </Pane>
  );
}

function ProjectFooter({ path, phase, onChoose }: { path: string | null; phase: Phase; onChoose: () => void }) {
  return (
    <div className="project-footer">
      <div className="font-caption secondary project-path" title={path ?? undefined}>
        {path ? home(path) : "Sin carpeta de proyecto"}
      </div>
      <div className="project-actions">
        <Button small onClick={onChoose}>
          {path ? "Cambiar…" : "Elegir carpeta…"}
        </Button>
        {path && (
          <Button small onClick={() => void call("reveal", { path })}>
            Abrir
          </Button>
        )}
      </div>
      {phase.phase === "building" && (
        <div className="font-caption secondary project-phase">
          <Spinner /> Compilando…
        </div>
      )}
      {phase.phase === "failed" && <div className="font-caption warning selectable">{phase.message}</div>}
    </div>
  );
}

function useRecipeForm(recipe: Recipe, names: string) {
  const [load, setLoad] = useState<RecipeFormLoad | null>(null);
  useEffect(() => {
    if (!desktop) return setLoad({ kind: "noForm" });
    let current = true;
    setLoad(null);
    void getRecipeSchema(recipe.id)
      .then((schema) => {
        if (!current) return;
        const empty = !schema || typeof schema !== "object" || !("properties" in schema) || Object.keys((schema as { properties: JSONObject }).properties ?? {}).length === 0;
        setLoad(empty ? { kind: "noForm" } : recipeFormLoad(schema as JSONValue));
      })
      .catch((failure) => current && setLoad({ kind: "problem", problem: errorText(failure) }));
    return () => {
      current = false;
    };
  }, [recipe.id, recipe.bundleFingerprint, recipe.base, names]);
  return load;
}

function RecipeDetail({
  recipe,
  data,
  isDefault,
  onSave,
  onDefault,
  onSaveAsForm,
}: {
  recipe: Recipe;
  data: Snapshot;
  isDefault: boolean;
  onSave: (recipe: Recipe) => Promise<void>;
  onDefault: () => void;
  onSaveAsForm: () => void;
}) {
  const names = useMemo(() => data.recipes.map((item) => item.name).join("|"), [data.recipes]);
  const load = useRecipeForm(recipe, names);
  const [name, setName] = useState(recipe.name);
  const [values, setValues] = useState<JSONObject>(recipe.values ?? {});
  const timer = useRef<number | undefined>(undefined);
  const latest = useRef(recipe);
  latest.current = recipe;
  const schedule = useCallback(
    (next: Partial<Recipe>) => {
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => void onSave({ ...latest.current, ...next }), 400);
    },
    [onSave],
  );
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const base = recipe.kind === "form" && recipe.base ? data.recipes.find((item) => item.id === recipe.base && item.kind === "code") : undefined;
  const usable = recipe.kind === "form" ? !recipe.base || Boolean(base) : Boolean(recipe.bundleFingerprint);
  const origin =
    recipe.kind === "form"
      ? !recipe.base
        ? "Ejecuta el código de serie de Escriba, el de «Por defecto», con estos valores."
        : base
          ? `Ejecuta el código de «${base.name}» con estos valores: si cambias su receta.ts, cambia también esta.`
          : `Su receta de código, «${recipe.base}», ya no está en el proyecto: no se puede usar.`
      : "";

  const parameters =
    load?.kind === "form" ? (
      <>
        <RecipeFormSections
          form={load.form}
          values={recipeFormValues(load.form, values)}
          onChange={(next) => {
            const overrides = recipeFormOverrides(load.form, next) ?? {};
            setValues(overrides);
            schedule({ values: overrides });
          }}
        />
        <FormSection
          footer={`Lo que cambias aquí se guarda para esta receta y vale para todas las notas que procese, también cuando otra receta se la pasa. Los valores de serie y las opciones salen de ${recipeFormExport}, en su código.`}
        >
          <FormRow>
            <Button
              onClick={() => {
                setValues({});
                schedule({ values: {} });
              }}
              disabled={Object.keys(values).length === 0}
            >
              Volver a los valores de serie
            </Button>
          </FormRow>
        </FormSection>
      </>
    ) : load?.kind === "problem" ? (
      <FormSection header="Parámetros">
        <FormRow>
          <span className="warning selectable">{load.problem}</span>
        </FormRow>
      </FormSection>
    ) : null;

  const defaultRow = isDefault ? (
    <FormRow>
      <span className="secondary default-note">
        <BadgeCheck size={14} strokeWidth={1.8} /> Es la receta por defecto: procesa todo lo que entra.
      </span>
    </FormRow>
  ) : (
    <FormRow>
      <Button onClick={onDefault} disabled={!usable}>
        Usar por defecto
      </Button>
    </FormRow>
  );

  return (
    <div className="form-pane">
      {recipe.kind === "form" ? (
        <FormSection footer={`${origin} Desde una receta de código se llama con escriba.receta("${name}").procesar(audio).`}>
          <LabeledRow label="Nombre">
            <InlineField
              value={name}
              onChange={(text) => {
                setName(text);
                if (text.trim()) schedule({ name: text.trim() });
              }}
            />
          </LabeledRow>
          {defaultRow}
        </FormSection>
      ) : (
        <FormSection footer="Se edita en la carpeta del proyecto, con tu editor o un agente. Escriba la compila al guardar.">
          <LabeledRow label="Nombre">{recipe.name}</LabeledRow>
          <LabeledRow label="Clave">{recipe.id}</LabeledRow>
          {defaultRow}
          <FormRow>
            <Button onClick={onSaveAsForm} disabled={!usable} title="Crea una receta con nombre propio que ejecuta este código con los valores que le dejes">
              Guardar como receta de formulario
            </Button>
          </FormRow>
          {!usable && (
            <FormRow>
              <span className="font-caption secondary">Todavía no ha compilado nunca: no se puede usar hasta que compile.</span>
            </FormRow>
          )}
        </FormSection>
      )}
      {usable && parameters}
      {recipe.kind === "code" && (
        <FormSection header="Compilación">
          <FormRow>
            <span className={`selectable ${recipe.error ? "warning" : "secondary"}`}>
              {recipe.error
                ? `error: ${recipe.error}${recipe.bundleFingerprint ? ` · sigue con ${recipe.bundleFingerprint.slice(0, 7)}` : " · sin paquete"}`
                : `compilada · ${recipe.bundleFingerprint?.slice(0, 7) ?? "sin paquete"}`}
            </span>
          </FormRow>
          {data.settings.projectPath && (
            <FormRow>
              <Button onClick={() => void call("reveal", { path: `${data.settings.projectPath}/recetas/${recipe.id}` }).catch((failure) => alertMessage("No se pudo", errorText(failure)))}>
                Abrir en el Finder
              </Button>
            </FormRow>
          )}
        </FormSection>
      )}
      {usable && <RecipeTestSection recipe={recipe} recordings={data.recordings} />}
      <RecipeRunsSection recipe={recipe} recordings={data.recordings} />
    </div>
  );
}

const shortDate = new Intl.DateTimeFormat("es-ES", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

function RecipeTestSection({ recipe, recordings }: { recipe: Recipe; recordings: Recording[] }) {
  const [note, setNote] = useState<string>("");
  const [testing, setTesting] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const [trace, setTrace] = useState<RecipeTrace | null>(null);
  const candidates = recordings.filter((recording) => recording.audioPath && recording.status !== "discarded").slice(0, 50);
  const run = async () => {
    if (!note) return;
    setTesting(true);
    setFailure(null);
    setTrace(null);
    try {
      await processRecording(note, { recipeId: recipe.id, dryRun: true });
    } catch (error) {
      setFailure(errorText(error));
    } finally {
      const traces = await call<RecipeTrace[]>("trace_list", { recordingId: note }).catch(() => []);
      setTrace(traces.filter((item) => item.dryRun && item.recipeId === recipe.id).sort((a, b) => b.finishedAt.localeCompare(a.finishedAt))[0] ?? null);
      setTesting(false);
    }
  };
  return (
    <FormSection
      header="Probar con una nota"
      footer="Ejecuta la receta sobre esa nota sin guardar versiones nuevas ni publicar: la traza dice qué habría publicado. Si la nota ya estaba transcrita con lo mismo, no vuelve a transcribir. Queda en sus ejecuciones como prueba."
    >
      <LabeledRow label="Nota">
        <PopupButton
          label="Nota"
          value={note || "__"}
          options={[
            { value: "__", label: "Elige una nota" },
            ...candidates.map((recording) => ({ value: recording.id, label: `${displayTitle(recording)} · ${shortDate.format(new Date(recording.createdAt))}` })),
          ]}
          onChange={(value) => setNote(value === "__" ? "" : value)}
        />
      </LabeledRow>
      <FormRow>
        <Button onClick={() => void run()} disabled={!note || testing}>
          {testing ? "Probando…" : "Probar"}
        </Button>
        {testing && <Spinner />}
      </FormRow>
      {failure && (
        <FormRow>
          <span className="font-caption warning selectable">{failure}</span>
        </FormRow>
      )}
      {trace && (
        <FormRow>
          <TraceDetail trace={trace} recipeName={recipe.name} />
        </FormRow>
      )}
    </FormSection>
  );
}

type Outcome = "all" | "ok" | "failed" | "waiting";

function RecipeRunsSection({ recipe, recordings }: { recipe: Recipe; recordings: Recording[] }) {
  const [outcome, setOutcome] = useState<Outcome>("all");
  const [traces, setTraces] = useState<RecipeTrace[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  useEffect(() => {
    if (!desktop) return setTraces([]);
    let current = true;
    void call<RecipeTrace[]>("trace_list", {})
      .then((all) => current && setTraces(all))
      .catch((error) => current && setProblem(errorText(error)));
    return () => {
      current = false;
    };
  }, [recipe.id]);
  const since = Date.now() - 30 * 86_400_000;
  const runs = (traces ?? [])
    .filter((trace) => trace.recipeId === recipe.id && new Date(trace.startedAt).getTime() >= since)
    .filter((trace) => outcome === "all" || traceOutcome(trace) === outcome)
    .sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  const title = (id: string) => {
    const recording = recordings.find((item) => item.id === id);
    return recording ? displayTitle(recording) : id;
  };
  return (
    <FormSection
      header="Ejecuciones"
      footer="Las de los últimos 30 días, también cuando la llamó otra receta. Lo que escribe con console.log sale en cada una."
    >
      <LabeledRow label="Resultado">
        <Segmented
          value={outcome}
          onChange={setOutcome}
          options={[
            { value: "all", label: "Todas" },
            { value: "ok", label: "Bien" },
            { value: "failed", label: "Falló" },
            { value: "waiting", label: "Esperando" },
          ]}
        />
      </LabeledRow>
      {problem && (
        <FormRow>
          <span className="font-caption warning">{problem}</span>
        </FormRow>
      )}
      {traces && runs.length === 0 && (
        <FormRow>
          <span className="secondary">{outcome === "all" ? "Todavía no se ha ejecutado." : "Ninguna con ese resultado."}</span>
        </FormRow>
      )}
      {runs.map((trace) => (
        <RunRow key={trace.id} trace={trace} title={title(trace.recordingId)} recipeName={recipe.name} />
      ))}
    </FormSection>
  );
}

function RunRow({ trace, title, recipeName }: { trace: RecipeTrace; title: string; recipeName: string }) {
  const [expanded, setExpanded] = useState(false);
  const outcome = traceOutcome(trace);
  const Icon = outcome === "ok" ? CheckCircle2 : outcome === "waiting" ? Clock : AlertTriangle;
  const subtitle = [trace.dryRun ? "probada" : null, recordingWhen(new Date(trace.startedAt), new Date())].filter(Boolean).join(" · ");
  const total = traceSeconds(trace);
  return (
    <FormRow>
      <div className="run">
        <button type="button" className="run-line" onClick={() => setExpanded(!expanded)}>
          <ChevronRight size={12} strokeWidth={2.4} className={`disclosure ${expanded ? "open" : ""}`} />
          <Icon size={14} strokeWidth={1.8} className={outcome === "ok" ? "secondary" : "warning"} />
          <span className="run-text">
            <span className="run-title">{title}</span>
            <span className="font-caption secondary">{subtitle}</span>
          </span>
          {Number.isFinite(total) && <span className="font-caption secondary monospaced-digits">{formatSeconds(total)} s</span>}
        </button>
        {expanded && <TraceDetail trace={trace} recipeName={recipeName} />}
      </div>
    </FormRow>
  );
}
