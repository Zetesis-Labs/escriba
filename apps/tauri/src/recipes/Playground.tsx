import { shortcut } from "../core/platform";
import { usePlatform } from "../app/platform";
import { EditorView, keymap } from "@codemirror/view";
import { javascript } from "@codemirror/lang-javascript";
import { autocompletion } from "@codemirror/autocomplete";
import { basicSetup } from "codemirror";
import { ChevronDown, ChevronRight, FileCode2, Folder, Plus } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { call } from "../api";
import { dirtyProjectDrafts, projectCreateArgs, projectDraft, projectDrafts, projectFileTree, projectFileVisible, projectSaveArgs, unsavedProjectFiles, updateProjectDrafts, type ProjectFileNode, type ProjectDrafts } from "../core/projectDrafts";
import { Button, ContentUnavailable, Spinner, TextField } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText } from "../mac/native";
import "./playground.css";

type Tool = "install" | "check" | "test";
type ProjectFiles = { files: string[] };
type ProjectSource = { source: string };
type ToolResult = { success: boolean; output: string };
const pendingDrafts = new Map<string, ProjectDrafts>();

function SourceEditor({ entry, source, onChange, onSave }: {
  entry: string;
  source: string;
  onChange: (source: string) => void;
  onSave: () => void;
}) {
  const parent = useRef<HTMLDivElement>(null);
  const changed = useRef(onChange);
  const save = useRef(onSave);
  changed.current = onChange;
  save.current = onSave;

  useEffect(() => {
    if (!parent.current) return;
    const typescript = /\.[cm]?tsx?$/.test(entry);
    const editor = new EditorView({
      parent: parent.current,
      doc: source,
      extensions: [
        basicSetup,
        /\.[cm]?[jt]sx?$/.test(entry) ? javascript({ typescript, jsx: /x$/.test(entry) }) : [],
        autocompletion(),
        keymap.of([{ key: "Mod-s", run: () => { save.current(); return true; } }]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) changed.current(update.state.doc.toString());
        }),
        EditorView.theme({
          "&": { height: "100%", backgroundColor: "transparent", color: "var(--label)" },
          ".cm-scroller": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: "12px" },
          ".cm-gutters": { backgroundColor: "var(--fill)", color: "var(--secondary)", borderRight: "0.5px solid var(--separator)" },
          ".cm-activeLine": { backgroundColor: "var(--fill)" },
        }),
      ],
    });
    return () => editor.destroy();
  }, [entry]);

  return <div className="playground-editor" ref={parent} aria-label={`Código de ${entry}`} />;
}

function FileBranch({ node, selected, drafts, onSelect }: {
  node: ProjectFileNode;
  selected: string | null;
  drafts: ProjectDrafts;
  onSelect: (entry: string) => void;
}) {
  const [open, setOpen] = useState(true);
  if (node.children) return (
    <div className="playground-branch">
      <button type="button" className="playground-directory" onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        <Folder size={13} strokeWidth={1.7} />
        <span>{node.name}</span>
      </button>
      {open && <div className="playground-children">{node.children.map((child) => <FileBranch key={child.path} node={child} selected={selected} drafts={drafts} onSelect={onSelect} />)}</div>}
    </div>
  );
  const dirty = projectDraft(drafts, node.path);
  return (
    <button type="button" className={`playground-file ${selected === node.path ? "selected" : ""}`} onClick={() => onSelect(node.path)} title={node.path} aria-current={selected === node.path ? "page" : undefined}>
      <FileCode2 size={13} strokeWidth={1.7} />
      <span>{node.name}</span>
      {dirty && dirty.source !== dirty.saved && <span className="playground-dirty" aria-label="Sin guardar">●</span>}
    </button>
  );
}

export function Playground({ path, onClose, onBuilt }: {
  path: string;
  onClose: () => void;
  onBuilt: () => Promise<void>;
}) {
  const platform = usePlatform();
  const [files, setFiles] = useState<string[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [drafts, setDrafts] = useState(() => pendingDrafts.get(path) ?? projectDrafts());
  const draftsRef = useRef(drafts);
  const loading = useRef(new Set<string>());
  const busy = useRef(false);
  const [creating, setCreating] = useState(false);
  const [newPath, setNewPath] = useState("");
  const [working, setWorking] = useState<string | null>(null);
  const [output, setOutput] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  const apply = useCallback((action: Parameters<typeof updateProjectDrafts>[1]) => {
    const next = updateProjectDrafts(draftsRef.current, action);
    draftsRef.current = next;
    setDrafts(next);
    const dirty = dirtyProjectDrafts(next);
    if (Object.keys(dirty).length) pendingDrafts.set(path, dirty);
    else pendingDrafts.delete(path);
  }, [path]);
  const openFile = useCallback(async (entry: string) => {
    setSelected(entry);
    if (projectDraft(draftsRef.current, entry) || loading.current.has(entry)) return;
    loading.current.add(entry);
    setProblem(null);
    try {
      const result = await call<ProjectSource>("project_read", { entry });
      apply({ type: "loaded", entry, source: result.source });
    } catch (error) {
      setProblem(errorText(error));
    } finally {
      loading.current.delete(entry);
    }
  }, [apply]);
  const listFiles = useCallback(async () => {
    try {
      const listed = await call<ProjectFiles>("project_list");
      setFiles(listed.files);
      setProblem(null);
      if (listed.files.length && !selected) void openFile(listed.files[0]);
    } catch (error) {
      setProblem(errorText(error));
      setFiles([]);
    }
  }, [openFile, selected]);
  useEffect(() => { void listFiles(); }, [path]);

  const saveFile = useCallback(async (entry: string) => {
    const draft = projectDraft(draftsRef.current, entry);
    if (!draft || draft.source === draft.saved || busy.current) return;
    busy.current = true;
    const source = draft.source;
    setWorking("Guardando");
    setProblem(null);
    try {
      await call("project_write", projectSaveArgs(entry, draft));
      apply({ type: "saved", entry, source });
      setOutput(`Guardado: ${entry}`);
    } catch (error) {
      setProblem(errorText(error));
    } finally {
      busy.current = false;
      setWorking(null);
    }
  }, [apply]);
  const reloadFile = async (entry: string) => {
    const draft = projectDraft(draftsRef.current, entry);
    if (!draft || busy.current) return;
    busy.current = true;
    try {
      if (draft.source !== draft.saved) {
        const confirmed = await confirmDestructive(
          `¿Descartar los cambios de «${entry}»?`,
          "Se volverá a leer el archivo del proyecto.",
          "Descartar y recargar",
        );
        if (!confirmed) return;
      }
      setWorking("Recargando");
      setProblem(null);
      const result = await call<ProjectSource>("project_read", { entry });
      apply({ type: "reloaded", entry, source: result.source });
      setOutput(`Recargado: ${entry}`);
    } catch (error) {
      setProblem(errorText(error));
    } finally {
      busy.current = false;
      setWorking(null);
    }
  };
  const createFile = async () => {
    if (busy.current) return;
    const entry = newPath.trim();
    if (!entry) return;
    if (!projectFileVisible(entry)) {
      setProblem("Usa una extensión visible: .ts, .tsx, .js, .mjs, .cjs, .json o .md.");
      return;
    }
    if (files?.includes(entry)) {
      setProblem(`Ya existe «${entry}».`);
      return;
    }
    busy.current = true;
    setWorking("Creando");
    setProblem(null);
    try {
      await call("project_write", projectCreateArgs(entry));
      const listed = await call<ProjectFiles>("project_list");
      setFiles(listed.files);
      apply({ type: "loaded", entry, source: "" });
      setSelected(entry);
      setNewPath("");
      setCreating(false);
      setOutput(`Creado: ${entry}`);
    } catch (error) {
      setProblem(errorText(error));
    } finally {
      busy.current = false;
      setWorking(null);
    }
  };
  const runTool = async (tool: Tool | "build") => {
    if (busy.current) return;
    const unsaved = unsavedProjectFiles(draftsRef.current);
    if (unsaved.length) {
      setProblem(`Guarda antes los archivos modificados: ${unsaved.join(", ")}.`);
      return;
    }
    busy.current = true;
    setWorking(tool);
    setProblem(null);
    setOutput("");
    try {
      if (tool === "build") {
        await call("runtime_run", { operation: "rebuildProject", args: {} });
        setOutput("Construcción terminada.");
        await onBuilt();
      } else {
        const result = await call<ToolResult>("project_tool", { tool });
        setOutput(result.output || (result.success ? "Terminó sin mensajes." : "La herramienta falló sin dar detalles."));
        if (!result.success) setProblem("La herramienta terminó con errores.");
      }
      if (tool === "install") await listFiles();
    } catch (error) {
      setProblem(errorText(error));
    } finally {
      busy.current = false;
      setWorking(null);
    }
  };
  const openInVSCode = async () => {
    if (busy.current) return;
    busy.current = true;
    setWorking("Abriendo VS Code");
    try {
      await call("project_open_vscode");
    } catch (error) {
      await alertMessage("No se pudo abrir VS Code", errorText(error));
    } finally {
      busy.current = false;
      setWorking(null);
    }
  };
  const tree = useMemo(() => projectFileTree(files ?? []), [files]);
  const draft = selected ? projectDraft(drafts, selected) : undefined;
  const dirty = draft && draft.source !== draft.saved;

  return (
    <div className="playground">
      <aside className="playground-files" aria-label="Archivos del proyecto">
        <div className="playground-files-header">
          <span className="font-headline">Archivos</span>
          <button type="button" className="list-bar-button" onClick={() => setCreating(true)} title="Nuevo archivo" aria-label="Nuevo archivo" disabled={Boolean(working)}><Plus size={14} /></button>
        </div>
        {creating && <div className="playground-new-file">
          <TextField value={newPath} onChange={setNewPath} placeholder="recetas/nueva/receta.ts" onSubmit={() => void createFile()} autoFocus />
          <div className="playground-new-actions"><Button small onClick={() => void createFile()} disabled={!newPath.trim() || Boolean(working)}>Crear</Button><Button small onClick={() => { setCreating(false); setNewPath(""); }}>Cancelar</Button></div>
        </div>}
        <div className="playground-file-tree">
          {files === null ? <div className="playground-empty"><Spinner /> Leyendo…</div> : tree.length ? tree.map((node) => <FileBranch key={node.path} node={node} selected={selected} drafts={drafts} onSelect={(entry) => void openFile(entry)} />) : <div className="playground-empty">No hay archivos del proyecto.</div>}
        </div>
        <div className="playground-project-path font-caption secondary" title={path}>{path}</div>
      </aside>
      <div className="list-detail-divider" />
      <div className="playground-main">
        <div className="playground-toolbar">
          <Button small onClick={onClose} disabled={Boolean(working)}>Volver a recetas</Button>
          <span className="playground-current" title={selected ?? undefined}>{selected ?? "Elige un archivo"}{dirty ? " ●" : ""}</span>
          {working && <Spinner />}
          <Button small onClick={() => selected && void reloadFile(selected)} disabled={!selected || !draft || Boolean(working)}>Recargar</Button>
          <Button small onClick={() => selected && void saveFile(selected)} disabled={!selected || !dirty || Boolean(working)}>Guardar</Button>
        </div>
        <div className="playground-tools" role="group" aria-label="Herramientas del proyecto">
          <Button small onClick={() => void runTool("install")} disabled={Boolean(working)}>Dependencias</Button>
          <Button small onClick={() => void runTool("check")} disabled={Boolean(working)}>Comprobar tipos</Button>
          <Button small onClick={() => void runTool("test")} disabled={Boolean(working)}>Pruebas</Button>
          <Button small prominent onClick={() => void runTool("build")} disabled={Boolean(working)}>Construir</Button>
          <div className="playground-external-editor">
            <Button small onClick={() => void openInVSCode()} disabled={Boolean(working)} title="Abre la carpeta del proyecto en Visual Studio Code">Abrir en VS Code</Button>
          </div>
        </div>
        <div className="playground-source">
          {selected && draft && working !== "Recargando" ? <SourceEditor key={selected} entry={selected} source={draft.source} onChange={(source) => apply({ type: "edited", entry: selected, source })} onSave={() => void saveFile(selected)} /> : <ContentUnavailable title={selected ? "Cargando archivo" : "Elige un archivo"} icon={FileCode2} description={`Los cambios se guardan con ${shortcut(platform, "S")} o con Guardar.`} />}
        </div>
        <div className="playground-console" aria-live="polite">
          <div className="font-caption secondary">Consola</div>
          {problem && <div className="warning">{problem}</div>}
          <pre>{output || (problem ? "" : "Ejecuta una herramienta para ver su resultado.")}</pre>
        </div>
      </div>
    </div>
  );
}
