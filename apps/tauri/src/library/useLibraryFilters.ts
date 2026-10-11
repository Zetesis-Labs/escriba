import { useCallback, useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { call, desktop } from "../api";
import type { LibraryFilter, SavedLibraryFilter, SaveLibraryFilter } from "../core/libraryFilters";
import type { OntologyDefinition } from "../knowledge/model";
import { errorText } from "../mac/native";
import { demoFilterCommand } from "./demoFilters";

const host = desktop ? call : demoFilterCommand;
type Result = { filter: LibraryFilter; ids: Set<string> | null; loading: boolean; error: string | null; name: string | null; incomplete?: boolean };

export function useLibraryFilters() {
  const [saved, setSaved] = useState<SavedLibraryFilter[]>([]);
  const [savedError, setSavedError] = useState<string | null>(null);
  const [catalog, setCatalog] = useState<OntologyDefinition[]>([]);
  const [catalogError, setCatalogError] = useState<string | null>(null);
  const [catalogLoading, setCatalogLoading] = useState(false);
  const [result, setResult] = useState<Result | null>(null);
  const [selectedSavedId, setSelectedSavedId] = useState<string | null>(null);
  const serial = useRef(0);
  const activeFilter = useRef<{ filter: LibraryFilter; name: string | null; savedId: string | null } | null>(null);

  const reloadSaved = useCallback(async () => {
    try { setSaved(await host<SavedLibraryFilter[]>("knowledge_filters_list")); setSavedError(null); }
    catch (failure) { setSavedError(errorText(failure)); }
  }, []);
  useEffect(() => { void reloadSaved(); }, [reloadSaved]);

  const loadCatalog = useCallback(async () => {
    setCatalogLoading(true); setCatalogError(null);
    try { setCatalog(await host<OntologyDefinition[]>("knowledge_list")); }
    catch (failure) { setCatalogError(errorText(failure)); }
    finally { setCatalogLoading(false); }
  }, []);

  const apply = useCallback(async (filter: LibraryFilter, name: string | null = null, savedId: string | null = null) => {
    const request = ++serial.current;
    activeFilter.current = { filter, name, savedId };
    setSelectedSavedId(savedId);
    setResult((previous) => previous?.incomplete && previous.filter === filter ? previous : { filter, ids: null, loading: true, error: null, name, incomplete: false });
    try {
      const answer = await host<{ recordingIds: string[]; incomplete?: boolean }>("knowledge_filter_notes", { filter });
      if (serial.current !== request) return;
      const incomplete = answer.incomplete === true;
      setResult({ filter, ids: new Set(answer.recordingIds), loading: false, error: null, name, incomplete });
      if (incomplete) window.setTimeout(() => { if (serial.current === request) void apply(filter, name, savedId); }, 3000);
    } catch (failure) {
      if (serial.current === request) setResult({ filter, ids: null, loading: false, error: errorText(failure), name, incomplete: false });
    }
  }, []);
  const clear = useCallback(() => { ++serial.current; activeFilter.current = null; setResult(null); setSelectedSavedId(null); }, []);
  useEffect(() => {
    if (!desktop) return;
    let alive = true;
    let stop: (() => void) | undefined;
    let timer: number | undefined;
    void listen("escriba://changed", () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        void reloadSaved();
        const current = activeFilter.current;
        if (current) void apply(current.filter, current.name, current.savedId);
      }, 450);
    }).then((unlisten) => { if (alive) stop = unlisten; else unlisten(); });
    return () => { alive = false; stop?.(); window.clearTimeout(timer); };
  }, [apply, reloadSaved]);
  const selectSaved = useCallback((filter: SavedLibraryFilter) => {
    void apply(filter.filter, filter.name, filter.id);
  }, [apply]);
  const save = useCallback(async (filter: SaveLibraryFilter) => {
    const stored = await host<SavedLibraryFilter>("knowledge_filter_save", { filter });
    await reloadSaved();
    return stored;
  }, [reloadSaved]);
  const remove = useCallback(async (id: string) => {
    await host("knowledge_filter_remove", { id });
    if (selectedSavedId === id) clear();
    await reloadSaved();
  }, [clear, reloadSaved, selectedSavedId]);

  return { saved, savedError, catalog, catalogError, catalogLoading, result, selectedSavedId, loadCatalog, apply, clear, selectSaved, save, remove };
}
export type LibraryFiltersController = ReturnType<typeof useLibraryFilters>;
