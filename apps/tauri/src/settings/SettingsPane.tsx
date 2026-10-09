import { homeDir } from "@tauri-apps/api/path";
import { FolderPlus, Settings, Trash2, type LucideIcon } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { call, desktop } from "../api";
import { Pane } from "../app/Pane";
import { abbreviatedPath, importReport } from "../core/settings";
import { folderDisplayName } from "../library/model";
import { Button, FormRow, FormSection, LabeledRow, Toggle } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText } from "../mac/native";
import type { Settings as AppSettings, Snapshot, WatchedFolder } from "../types";
import "./settings.css";

function Block({ title, icon: Icon, children }: { title: string; icon: LucideIcon; children: ReactNode }) {
  return (
    <section className="settings-block">
      <h2 className="settings-block-title font-title3">
        <Icon size={17} strokeWidth={1.8} />
        {title}
      </h2>
      {children}
    </section>
  );
}

function useHome() {
  const [home, setHome] = useState<string | null>(null);
  useEffect(() => {
    if (desktop) void homeDir().then(setHome).catch(() => undefined);
  }, []);
  return home;
}

export function SettingsPane({ data, refresh }: { data: Snapshot; refresh: () => Promise<void> }) {
  const settings = data.settings;
  const home = useHome();
  const [busy, setBusy] = useState(false);

  const perform = async (work: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await work();
    } catch (failure) {
      await alertMessage("No se pudo", errorText(failure));
    } finally {
      setBusy(false);
      await refresh();
    }
  };
  const save = (patch: Partial<AppSettings>) => perform(() => call("settings_save", { settings: patch }));
  const authorize = (options: { folderId?: string; style?: WatchedFolder["style"] }) => perform(() => call("watch_folder_authorize", options));
  const remove = (folder: WatchedFolder) => save({ watchedFolders: settings.watchedFolders.filter((item) => item.id !== folder.id) });
  const importLibrary = async () => {
    const confirmed = await confirmDestructive(
      "¿Importar la biblioteca de Escriba?",
      "Se copian las notas, el audio y las carpetas vigiladas de la app Escriba. La biblioteca de origen no se toca y lo que ya está aquí no se duplica.",
      "Importar",
    );
    if (confirmed) await perform(async () => alertMessage("Biblioteca importada", importReport(await call("library_import", {}))));
  };
  const issue = (folder: WatchedFolder) => data.watchIssues?.find((item) => item.folderId === folder.id);
  const hasVoiceMemos = settings.watchedFolders.some((folder) => folder.style === "voiceMemos");

  return (
    <Pane title="Ajustes">
      <div className="form-pane settings-pane">
        <Block title="General" icon={Settings}>
          <FormSection
            footer="Los problemas se notifican siempre."
          >
            <LabeledRow label="Arrancar al iniciar sesión">
              <Toggle label="Arrancar al iniciar sesión" checked={settings.launchAtLogin} onChange={(launchAtLogin) => void save({ launchAtLogin })} />
            </LabeledRow>
            <LabeledRow label="Notificar cada transcripción">
              <Toggle label="Notificar cada transcripción" checked={settings.notifyEveryNote !== false} onChange={(notifyEveryNote) => void save({ notifyEveryNote })} />
            </LabeledRow>
          </FormSection>
        </Block>
        <Block title="Carpetas vigiladas" icon={FolderPlus}>
          <FormSection>
            <FormRow>
              <div className="folder-text">
                <span>Bandeja de Escriba</span>
                <span className="font-caption secondary">Lo que grabas en la app y los audios que arrastras</span>
              </div>
            </FormRow>
          </FormSection>
          <FormSection
            header="Carpetas vigiladas"
            footer="Cualquier audio que caiga en ellas lo procesa la receta por defecto, que se configura en Recetas. macOS pide autorizar cada carpeta una vez; si aun así no deja leerla, la alternativa es el acceso total al disco."
          >
            {settings.watchedFolders.length === 0 && (
              <FormRow>
                <span className="secondary">Ninguna carpeta vigilada.</span>
              </FormRow>
            )}
            {settings.watchedFolders.map((folder) => {
              const problem = issue(folder);
              return (
                <FormRow key={folder.id}>
                  <div className="folder-text">
                    <span>{folderDisplayName(folder)}</span>
                    <span className="font-caption secondary folder-path" title={folder.path}>
                      {abbreviatedPath(folder.path, home)}
                    </span>
                    {problem && <span className="font-caption folder-problem">No se puede leer esta carpeta</span>}
                  </div>
                  {(problem || !folder.authorizationSaved) && (
                    <Button small disabled={busy} onClick={() => void authorize({ folderId: folder.id })}>
                      {folder.authorizationSaved ? "Volver a autorizar…" : "Autorizar…"}
                    </Button>
                  )}
                  <button type="button" className="folder-remove" title={`Dejar de vigilar ${folderDisplayName(folder)}`} aria-label={`Dejar de vigilar ${folderDisplayName(folder)}`} disabled={busy} onClick={() => void remove(folder)}>
                    <Trash2 size={15} />
                  </button>
                </FormRow>
              );
            })}
          </FormSection>
          <FormSection>
            <FormRow>
              <Button disabled={busy} onClick={() => void authorize({ style: "any" })}>
                Añadir carpeta…
              </Button>
            </FormRow>
            <FormRow>
              <Button disabled={busy || hasVoiceMemos} onClick={() => void authorize({ style: "voiceMemos" })}>
                Añadir Notas de Voz
              </Button>
            </FormRow>
            <FormRow>
              <Button disabled={busy} onClick={() => void perform(() => call("open_privacy_settings", { pane: "disk" }))}>
                Acceso total al disco…
              </Button>
            </FormRow>
          </FormSection>
          <FormSection footer="Copia las notas de la app Escriba de siempre. Se hace solo la primera vez que se abre esta app.">
            <FormRow>
              <Button disabled={busy} onClick={() => void importLibrary()}>
                Importar la biblioteca de Escriba…
              </Button>
            </FormRow>
          </FormSection>
        </Block>
      </div>
    </Pane>
  );
}
