import { homeDir } from "@tauri-apps/api/path";
import { Circle, Minus, Plus, Share } from "lucide-react";
import { useEffect, useState } from "react";
import { call, desktop } from "../api";
import { Pane } from "../app/Pane";
import { connectorProblem, connectorSubtitle, isAppConnector, makeConnector, nextConnectorName, removalText, type ConnectorKind } from "../core/connectors";
import { ContentUnavailable, ListBar, ListBarButton } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText, item, popupMenu } from "../mac/native";
import type { Snapshot } from "../types";
import { ConnectorEditor } from "./ConnectorEditor";
import "./connectors.css";

export function ConnectorsPane({ data, refresh }: { data: Snapshot; refresh: () => Promise<void> }) {
  const destinations = data.destinations.filter((destination) => isAppConnector(destination) && data.accounts.some((account) => account.id === destination.id && account.provider === destination.provider));
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [home, setHome] = useState<string | null>(null);
  useEffect(() => {
    if (desktop) void homeDir().then(setHome).catch(() => undefined);
  }, []);
  useEffect(() => {
    if (!selected && destinations.length) setSelected(destinations[0].id);
    if (selected && !destinations.some((destination) => destination.id === selected)) setSelected(destinations[0]?.id ?? null);
  }, [selected, destinations]);

  const add = async (kind: ConnectorKind) => {
    setBusy(true);
    const id = crypto.randomUUID();
    const created = makeConnector(kind, id, nextConnectorName(kind, destinations.map((destination) => destination.name)));
    try {
      await call("connector_save", created);
      setSelected(id);
    } catch (failure) {
      await alertMessage("No se pudo añadir", errorText(failure));
    } finally {
      setBusy(false);
      await refresh();
    }
  };
  const remove = async () => {
    const destination = destinations.find((candidate) => candidate.id === selected);
    if (!destination) return;
    const confirmed = await confirmDestructive(`¿Quitar «${destination.name}»?`, removalText(destination.provider), "Quitar");
    if (!confirmed) return;
    setBusy(true);
    try {
      await call("connector_remove", { id: destination.id });
      setSelected(null);
    } catch (failure) {
      await alertMessage("No se pudo quitar", errorText(failure));
    } finally {
      setBusy(false);
      await refresh();
    }
  };
  const destination = destinations.find((candidate) => candidate.id === selected);
  const account = data.accounts.find((candidate) => candidate.id === selected);

  return (
    <Pane title="Conectores">
      <div className="connectors-layout">
        <div className="connectors-list">
          <div className="connectors-list-items" role="listbox" aria-label="Conectores">
            {destinations.map((candidate) => {
              const owner = data.accounts.find((entry) => entry.id === candidate.id);
              if (!owner) return null;
              const live = candidate.enabled && connectorProblem(owner, candidate) === null;
              return (
                <div key={candidate.id} role="option" aria-selected={candidate.id === selected} className={`list-row connector-row ${candidate.id === selected ? "selected" : ""}`} onMouseDown={() => setSelected(candidate.id)}>
                  <Circle size={9} fill={live ? "var(--green)" : "none"} color={live ? "var(--green)" : "var(--secondary)"} strokeWidth={2} />
                  <div className="connector-row-text">
                    <div>{candidate.name}</div>
                    <div className="font-caption secondary" title={connectorSubtitle(candidate, home)}>{connectorSubtitle(candidate, home)}</div>
                  </div>
                </div>
              );
            })}
          </div>
          <ListBar>
            <ListBarButton icon={Plus} label="Añadir conector" disabled={busy} onClick={(event) => void popupMenu([item("Notion", () => void add("notion")), item("OKF", () => void add("okf"))], event.currentTarget)} />
            <ListBarButton icon={Minus} label="Quitar conector" disabled={!selected || busy} onClick={() => void remove()} />
          </ListBar>
        </div>
        <div className="connectors-divider" />
        <div className="connectors-detail">
          {destinations.map((entry) => {
            const owner = data.accounts.find((candidate) => candidate.id === entry.id);
            return owner ? <div className="connector-editor-host" hidden={entry.id !== selected} key={entry.id}><ConnectorEditor account={owner} destination={entry} refresh={refresh} home={home} /></div> : null;
          })}
          {(!destination || !account) && (
            <ContentUnavailable title="Sin conector elegido" icon={Share} description="Añade uno con + o elige uno de la lista." />
          )}
        </div>
      </div>
    </Pane>
  );
}
