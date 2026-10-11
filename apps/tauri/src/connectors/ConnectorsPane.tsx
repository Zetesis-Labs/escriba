import { homeDir } from "@tauri-apps/api/path";
import { Circle, Minus, Plus, Share } from "lucide-react";
import { useEffect, useState } from "react";
import { call } from "../api";
import { Pane } from "../app/Pane";
import { availableProviders } from "../core/connectorFields";
import { isAppConnector, nextConnectorName } from "../core/connectors";
import { ContentUnavailable, ListBar, ListBarButton } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText, item, popupMenu } from "../mac/native";
import type { Snapshot } from "../types";
import { ConnectorEditor } from "./ConnectorEditor";
import "./connectors.css";

export function ConnectorsPane({ data, refresh }: { data: Snapshot; refresh: () => Promise<void> }) {
  const providers = availableProviders(data.providers);
  const destinations = data.destinations.filter((destination) => isAppConnector(destination));
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [home, setHome] = useState<string | null>(null);
  const [subtitles, setSubtitles] = useState<Record<string, string>>({});
  useEffect(() => {
    void homeDir().then(setHome).catch(() => undefined);
  }, []);
  useEffect(() => {
    if (!selected && destinations.length) setSelected(destinations[0].id);
    if (selected && !destinations.some((destination) => destination.id === selected)) setSelected(destinations[0]?.id ?? null);
  }, [selected, destinations]);

  const add = async (providerId: string) => {
    const provider = providers.find((entry) => entry.id === providerId);
    if (!provider || provider.unavailable) return;
    setBusy(true);
    const id = crypto.randomUUID();
    const name = nextConnectorName(provider.name, destinations.map((destination) => destination.name));
    try {
      await call("connector_save", {
        account: { id, name, provider: provider.id, enabled: false, ...(provider.origin ? { origin: provider.origin } : {}) },
        destination: { id, name, provider: provider.id, account: id, enabled: false, configuration: provider.defaultConfiguration },
      });
      setSelected(id);
      await refresh();
    } catch (failure) {
      await alertMessage("No se pudo añadir", errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const remove = async () => {
    const destination = destinations.find((candidate) => candidate.id === selected);
    if (!destination) return;
    const provider = providers.find((entry) => entry.id === destination.provider);
    const confirmed = await confirmDestructive(`¿Quitar «${destination.name}»?`, provider?.removalMessage ?? "Se borran su configuración y credenciales. Las publicaciones anteriores permanecen en el servicio o carpeta.", "Quitar");
    if (!confirmed) return;
    setBusy(true);
    try {
      await call("connector_remove", { id: destination.id });
      setSelected(null);
      await refresh();
    } catch (failure) {
      await alertMessage("No se pudo quitar", errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const destination = destinations.find((candidate) => candidate.id === selected);
  const account = data.accounts.find((candidate) => candidate.id === destination?.account);
  return <Pane title="Conectores">
    <div className="connectors-layout">
      <div className="connectors-list">
        <div className="connectors-list-items" role="listbox" aria-label="Conectores">
          {destinations.map((candidate) => {
            const owner = data.accounts.find((entry) => entry.id === candidate.account);
            const provider = providers.find((entry) => entry.id === candidate.provider);
            const live = !!owner && !!provider && candidate.enabled && owner.enabled && !provider.unavailable;
            const subtitle = provider?.unavailable || !provider ? "Proveedor no disponible" : subtitles[candidate.id] ?? provider.name;
            return <div key={candidate.id} role="option" aria-selected={candidate.id === selected} className={`list-row connector-row ${candidate.id === selected ? "selected" : ""}`} onMouseDown={() => setSelected(candidate.id)}>
              <Circle size={9} fill={live ? "var(--green)" : "none"} color={live ? "var(--green)" : "var(--secondary)"} strokeWidth={2} />
              <div className="connector-row-text"><div>{candidate.name}</div><div className="font-caption secondary" title={subtitle}>{subtitle}</div></div>
            </div>;
          })}
        </div>
        <ListBar>
          <ListBarButton icon={Plus} label="Añadir conector" disabled={busy} onClick={(event) => void popupMenu(providers.filter((provider) => !provider.unavailable).map((provider) => item(provider.name, () => void add(provider.id))), event.currentTarget)} />
          <ListBarButton icon={Minus} label="Quitar conector" disabled={!selected || busy} onClick={() => void remove()} />
        </ListBar>
      </div>
      <div className="connectors-divider" />
      <div className="connectors-detail">
        {destinations.map((entry) => {
          const owner = data.accounts.find((candidate) => candidate.id === entry.account);
          const provider = providers.find((candidate) => candidate.id === entry.provider);
          return <div className="connector-editor-host" hidden={entry.id !== selected} key={entry.id}><ConnectorEditor account={owner} destination={entry} provider={provider} refresh={refresh} home={home} onSubtitle={(subtitle) => setSubtitles((current) => current[entry.id] === subtitle ? current : { ...current, [entry.id]: subtitle })} /></div>;
        })}
        {!destination && <ContentUnavailable title="Sin conector elegido" icon={Share} description="Añade uno con + o elige uno de la lista." />}
        {destination && !account && <ContentUnavailable title="Cuenta no disponible" icon={Share} description="Este destino conserva sus datos, pero su cuenta no está disponible." />}
      </div>
    </div>
  </Pane>;
}
