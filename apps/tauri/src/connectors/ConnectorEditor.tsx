import { builtinProviders, type Configuration, type ConnectorAction, type ConnectorEditorResult, type ConnectorField, type ConnectorView, type Provider } from "@escriba/conectores";
import { open } from "@tauri-apps/plugin-dialog";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { call } from "../api";
import { accessChanged, connectorDraftDirty, editorRequest, fieldValue, isSafeFieldPath, needsScopeAuthorization, providerAccess, reconcileConnectorDraft, scopeAuthorizationKey, setFieldValue, visibleValidationProblem, type ValidationIssue } from "../core/connectorFields";
import { abbreviatedPath } from "../core/settings";
import { Button, FormRow, FormSection, InlineField, LabeledRow, PopupButton, Toggle } from "../mac/controls";
import { alertMessage, errorText } from "../mac/native";
import { connectorEditor } from "../runtime";
import type { Account, Destination, JSONValue } from "../types";
import { TokenEditor } from "./TokenEditor";

function SaveBar({ dirty, busy, discard, save }: { dirty: boolean; busy: boolean; discard: () => void; save: () => void }) {
  return <div className="bottom-bar connector-save-bar">
    {dirty && <span className="font-caption secondary">Cambios sin guardar</span>}
    <span className="grow" />
    <Button disabled={!dirty || busy} onClick={discard}>Descartar</Button>
    <Button prominent disabled={!dirty || busy} onClick={save}>Guardar</Button>
  </div>;
}

function SectionText({ children, problem }: { children: ReactNode; problem?: boolean }) {
  return <div className={`font-caption ${problem ? "connector-error" : "secondary"}`}>{children}</div>;
}

function ActionButton({ action, onAction }: { action: ConnectorAction; onAction: (action: string) => void }) {
  return action.destructive
    ? <button className="mac-button small connector-action-danger" type="button" disabled={action.disabled} onClick={() => onAction(action.id)}>{action.label}</button>
    : <Button small disabled={action.disabled} onClick={() => onAction(action.id)}>{action.label}</Button>;
}

function editableDestination(destination: Destination): Omit<Destination, "program" | "programFingerprint"> {
  const copy = { ...destination };
  delete copy.program;
  delete copy.programFingerprint;
  return copy;
}

export function ConnectorFieldControl({ field, configuration, onChange, onAction, home, inline = false }: {
  field: ConnectorField;
  configuration: Configuration;
  onChange: (field: ConnectorField, value: JSONValue) => void;
  onAction: (action: string, value?: JSONValue) => void;
  home: string | null;
  inline?: boolean;
}) {
  if (!isSafeFieldPath(field.path)) return <LabeledRow label={field.label}><SectionText problem>El proveedor declaró una ruta de campo no válida.</SectionText></LabeledRow>;
  const raw = field.path.length ? fieldValue(configuration, field.path) : "value" in field ? field.value as JSONValue : undefined;
  const value = typeof raw === "string" ? raw : "";
  if (field.disabled) {
    const display = field.options?.find((option) => JSON.stringify(option.value) === JSON.stringify(raw))?.label ?? (raw === undefined || raw === null ? "" : typeof raw === "object" ? JSON.stringify(raw) : String(raw));
    return inline ? <div className="connector-inline-field"><span className="secondary">{display}</span></div> : <LabeledRow label={field.label}><span className="secondary">{display}</span></LabeledRow>;
  }
  const change = (next: JSONValue) => {
    if (field.action) onAction(field.action, next);
    else onChange(field, next);
  };
  let control: ReactNode;
  if (field.type === "boolean") {
    control = <Toggle checked={raw === true} onChange={(checked) => change(checked)} label={field.label} />;
  } else if (field.type === "select") {
    const options = field.options ?? [];
    const chosen = options.findIndex((option) => JSON.stringify(option.value) === JSON.stringify(raw));
    control = <PopupButton value={chosen < 0 ? "" : String(chosen)} label={field.label} options={[{ value: "", label: "Elegir…" }, ...options.map((option, index) => ({ value: String(index), label: option.label }))]} onChange={(selected) => {
      if (selected === "") return;
      const option = options[Number(selected)];
      if (option) change(option.value);
    }} />;
  } else if (field.type === "number") {
    control = <input className="text-field" type="number" aria-label={field.label} value={typeof raw === "number" ? raw : ""} placeholder={field.placeholder} disabled={field.disabled} onChange={(event) => change(event.target.value === "" ? null : Number(event.target.value))} />;
  } else if (field.type === "textarea") {
    control = <textarea className="text-field connector-textarea" aria-label={field.label} value={value} placeholder={field.placeholder} disabled={field.disabled} onChange={(event) => change(event.target.value)} />;
  } else if (field.type === "template") {
    control = <TokenEditor value={value} onChange={(next) => change(next)} context={field.context ?? "body"} links={field.links} current={field.current} placeholder={field.placeholder} multiline={field.multiline} />;
  } else if (field.type === "folder") {
    control = <div className="connector-folder-control">
      <span className="connector-folder" title={value}>{value ? abbreviatedPath(value, home) : "Sin elegir"}</span>
      {value && <Button small onClick={() => void call("reveal", { path: value }).catch((failure) => alertMessage("No se pudo mostrar la carpeta", errorText(failure)))}>Mostrar en Finder</Button>}
      <Button small onClick={() => void open({ directory: true, title: field.label }).then((path) => { if (typeof path === "string") change(path); }).catch((failure) => alertMessage("No se pudo elegir la carpeta", errorText(failure)))}>Elegir…</Button>
    </div>;
  } else {
    control = <InlineField value={value} onChange={(next) => change(next)} placeholder={field.placeholder} />;
  }
  if (inline) return <div className="connector-inline-field" role="group" aria-label={field.label}><div className="connector-field-value">{control}</div></div>;
  return <LabeledRow label={field.label}><div className="connector-field-value">{control}{field.help && <SectionText>{field.help}</SectionText>}</div></LabeledRow>;
}

export function ConnectorViewFields({ view, configuration, onChange, onAction, home }: {
  view: ConnectorView;
  configuration: Configuration;
  onChange: (field: ConnectorField, value: JSONValue) => void;
  onAction: (action: string, value?: JSONValue) => void;
  home: string | null;
}) {
  return <>
    {view.sections.map((section, index) => <FormSection key={index} header={section.title} footer={section.help}>
      {section.fields.flatMap((entry, position, fields) => {
        if (entry.row) {
          if (position > 0 && fields[position - 1].row === entry.row) return [];
          const grouped = [];
          for (let next = position; next < fields.length && fields[next].row === entry.row; next++) grouped.push(fields[next]);
          return [<FormRow key={`row-${entry.row}`}><div className="connector-grouped-fields">{grouped.map((part, index) => part.type === "action"
            ? part.destructive
              ? <button key={index} className="connector-property-remove" type="button" aria-label={part.label} title={part.label} disabled={part.disabled} onClick={() => onAction(part.id)}>⊗</button>
              : <ActionButton key={index} action={part} onAction={onAction} />
            : <ConnectorFieldControl key={index} field={part} configuration={configuration} onChange={onChange} onAction={onAction} home={home} inline />)}</div></FormRow>];
        }
        if (entry.type !== "action") return [<ConnectorFieldControl key={`field-${entry.path.join("/")}-${position}`} field={entry} configuration={configuration} onChange={onChange} onAction={onAction} home={home} />];
        if (position > 0 && fields[position - 1].type === "action") return [];
        const actions: ConnectorAction[] = [];
        for (let next = position; next < fields.length && fields[next].type === "action"; next++) actions.push(fields[next] as ConnectorAction);
        return [<FormRow key={`actions-${position}`}><div className="connector-actions">{actions.map((action) => <ActionButton key={action.id} action={action} onAction={onAction} />)}</div></FormRow>];
      })}
    </FormSection>)}
    {view.previews?.map((preview, index) => <FormSection key={index} header={preview.title ?? "Así queda"}>
      <div className="connector-preview">
        {preview.properties && <div className="connector-preview-grid">{preview.properties.map((property, position) => <div className="connector-preview-row" key={position}><span className="secondary">{property.label}</span><span>{property.value}</span></div>)}</div>}
        {preview.text && <div className="connector-preview-body">{preview.text}</div>}
      </div>
    </FormSection>)}
  </>;
}

export function ConnectorEditor({ account, destination, provider, refresh, home, onSubtitle }: {
  account?: Account;
  destination: Destination;
  provider?: Provider;
  refresh: () => Promise<void>;
  home: string | null;
  onSubtitle?: (subtitle: string) => void;
}) {
  const [configuration, setConfiguration] = useState<Configuration>(destination.configuration);
  const [state, setState] = useState<Configuration>({});
  const [view, setView] = useState<ConnectorView | null>(null);
  const [name, setName] = useState(destination.name);
  const [enabled, setEnabled] = useState(destination.enabled);
  const [token, setToken] = useState("");
  const [hasCredential, setHasCredential] = useState(account?.hasCredential === true);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [validationIssue, setValidationIssue] = useState<ValidationIssue | null>(null);
  const [acceptedScope, setAcceptedScope] = useState<string | null>(null);
  const revision = useRef(0);
  const previousSaved = useRef({ id: destination.id, name: destination.name, enabled: destination.enabled, configuration: destination.configuration });
  const requested = provider ? providerAccess(provider) : null;
  const newAuthorization = !!requested && !account?.grant && !builtinProviders.some((entry) => entry.id === provider?.id);
  const changedAuthorization = !!requested && accessChanged(account?.grant, requested);
  const needsReconnect = newAuthorization || changedAuthorization;
  const scopeKey = provider ? scopeAuthorizationKey(provider, configuration) : null;
  const scopeNeedsAuthorization = !!provider && !!account && needsScopeAuthorization(provider, account, configuration);
  const dirty = connectorDraftDirty(destination, { name, enabled, configuration }, token, scopeNeedsAuthorization && acceptedScope === scopeKey);
  const providerId = provider?.id;
  const configurationKey = JSON.stringify(configuration);
  const stateKey = JSON.stringify(state);
  const savedKey = JSON.stringify({ id: destination.id, name: destination.name, enabled: destination.enabled, configuration: destination.configuration });

  useEffect(() => () => { revision.current++; }, [providerId, provider?.program, provider?.programFingerprint, provider?.unavailable]);

  useEffect(() => { setHasCredential(account?.hasCredential === true); }, [account?.hasCredential]);

  useEffect(() => {
    const previous = previousSaved.current;
    if (JSON.stringify(previous) === savedKey) return;
    previousSaved.current = { id: destination.id, name: destination.name, enabled: destination.enabled, configuration: destination.configuration };
    const reconciled = reconcileConnectorDraft(previous, { name, enabled, configuration }, destination);
    if (reconciled.name !== name) setName(reconciled.name);
    if (reconciled.enabled !== enabled) setEnabled(reconciled.enabled);
    if (reconciled.configuration !== configuration) {
      revision.current++;
      setConfiguration(reconciled.configuration);
    }
  }, [savedKey]);

  useEffect(() => {
    if (!providerId || provider?.unavailable) return;
    const sequence = ++revision.current;
    void connectorEditor("describe", editorRequest(providerId, account, configuration, state)).then((result) => {
      if (revision.current !== sequence) return;
      setView(result.view ?? null);
      if (result.view?.subtitle) onSubtitle?.(result.view.subtitle);
      setProblem(result.problem ?? null);
    }).catch((failure) => {
      if (revision.current === sequence) setProblem(errorText(failure));
    });
  }, [providerId, provider?.program, provider?.programFingerprint, provider?.unavailable, account?.id, configurationKey, stateKey]);

  const discard = () => {
    revision.current++;
    setConfiguration(destination.configuration);
    setState({});
    setName(destination.name);
    setEnabled(destination.enabled);
    setToken("");
    setProblem(null);
    setValidationIssue(null);
    setAcceptedScope(null);
  };
  const runAction = async (action: string, value?: JSONValue, nextConfiguration = configuration) => {
    if (!provider || provider.unavailable) return;
    const sequence = ++revision.current;
    setBusy(true);
    setProblem(null);
    try {
      const result = await connectorEditor("action", { ...editorRequest(provider.id, account, nextConfiguration, state), action, value });
      if (revision.current !== sequence) return;
      if (result.configuration) setConfiguration(result.configuration);
      if (result.state) setState(result.state);
      if (result.view) setView(result.view);
      if (result.view?.subtitle) onSubtitle?.(result.view.subtitle);
      setProblem(result.problem ?? null);
    } catch (failure) {
      if (revision.current === sequence) setProblem(errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const changeField = (field: ConnectorField, value: JSONValue) => {
    revision.current++;
    setConfiguration((current) => setFieldValue(current, field.path, value));
  };
  const fieldAction = (action: string, value?: JSONValue) => {
    const field = view?.sections.flatMap((section) => section.fields).find((entry): entry is ConnectorField => entry.type !== "action" && entry.action === action);
    const next = field && value !== undefined ? setFieldValue(configuration, field.path, value) : configuration;
    void runAction(action, value, next);
  };
  const persist = async (grant: boolean, nextEnabled = enabled) => {
    if (!account || !provider || !requested) throw Error("La cuenta o el proveedor no está disponible");
    const nextAccount: Account = { ...account, name, enabled: grant ? true : account.enabled, folder: typeof configuration.folder === "string" ? configuration.folder : account.folder, ...(grant ? { grant: requested, ...(requested.origin ? { origin: requested.origin } : {}) } : {}) };
    await call("connector_save", { account: nextAccount, destination: { ...editableDestination(destination), name, enabled: nextEnabled, configuration } });
  };
  const save = async () => {
    if (!provider || provider.unavailable) return;
    setBusy(true);
    setProblem(null);
    try {
      const validation: ConnectorEditorResult = await connectorEditor("validate", editorRequest(provider.id, account, configuration, state));
      if (validation.valid === false) {
        setValidationIssue({ configuration: configurationKey, message: validation.problem ?? "Revisa la configuración." });
        if (enabled) return;
      } else setValidationIssue(null);
      if (scopeNeedsAuthorization && acceptedScope !== scopeKey) {
        setProblem("Autoriza el acceso solicitado antes de guardar.");
        return;
      }
      if (enabled && provider.credential && !hasCredential && !token.trim()) {
        setProblem(`Introduce la credencial de ${provider.name} antes de activar este conector.`);
        return;
      }
      if (needsReconnect && enabled && provider.credential && !token.trim()) {
        setProblem("El proveedor pide un alcance distinto. Pega la credencial y vuelve a conectar.");
        return;
      }
      if (needsReconnect && token.trim() && hasCredential) {
        await call("credential_save", { id: account?.id, value: "" });
        setHasCredential(false);
      }
      await persist(!needsReconnect || !provider.credential || !!token.trim(), enabled);
      if (token.trim()) {
        await call("credential_save", { id: account?.id, value: token.trim() });
        setHasCredential(true);
        setToken("");
      }
      await refresh();
      setProblem(null);
    } catch (failure) {
      setProblem(errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const connect = async () => {
    if (!account || !provider || (!token.trim() && (!hasCredential || needsReconnect))) return;
    setBusy(true);
    setProblem(null);
    try {
      const validation = await connectorEditor("validate", editorRequest(provider.id, account, configuration, state));
      const connectingEnabled = validation.valid === false ? false : enabled;
      setValidationIssue(validation.valid === false ? { configuration: configurationKey, message: validation.problem ?? "Revisa la configuración." } : null);
      if (needsReconnect && token.trim() && hasCredential) {
        await call("credential_save", { id: account.id, value: "" });
        setHasCredential(false);
      }
      await persist(true, connectingEnabled);
      if (!connectingEnabled) setEnabled(false);
      if (token.trim()) {
        await call("credential_save", { id: account.id, value: token.trim() });
        setHasCredential(true);
        setToken("");
      }
      await refresh();
      if (provider.connectAction) await runAction(provider.connectAction);
    } catch (failure) {
      setProblem(errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  const disconnect = async () => {
    if (!account) return;
    setBusy(true);
    try {
      await call("credential_save", { id: account.id, value: "" });
      await call("connector_save", { account: { ...account, enabled: false }, destination: { ...editableDestination(destination), enabled: false } });
      setHasCredential(false);
      setToken("");
      setEnabled(false);
      await refresh();
    } catch (failure) {
      setProblem(errorText(failure));
    } finally {
      setBusy(false);
    }
  };
  if (!provider || provider.unavailable || !account) return <div className="connector-form"><FormSection header="Proveedor no disponible"><FormRow><SectionText problem>La integración «{destination.provider}» no está disponible. Se conserva la cuenta y su configuración hasta que vuelvas a cargar el proyecto.</SectionText></FormRow></FormSection></div>;
  return <form className="connector-editor" onSubmit={(event) => { event.preventDefault(); if (dirty && !busy) void save(); }}>
    <button type="submit" hidden>Guardar</button>
    <div className="form-pane connector-form" inert={busy}>
      <FormSection>
        <LabeledRow label="Nombre"><InlineField value={name} onChange={setName} /></LabeledRow>
        <LabeledRow label={provider.autoPublishLabel ?? "Publicar cada transcripción nueva"}><Toggle checked={enabled} onChange={setEnabled} label={provider.autoPublishLabel ?? "Publicar cada transcripción nueva"} /></LabeledRow>
        {provider.description && <FormRow><SectionText>{provider.description}</SectionText></FormRow>}
      </FormSection>
      {provider.credential && <FormSection header={provider.credential.label} footer={provider.credential.help}>
        <FormRow><input className="text-field" type="password" value={token} onChange={(event) => setToken(event.target.value)} placeholder={provider.credential.label} aria-label={provider.credential.label} autoComplete="off" /></FormRow>
        {provider.origin && <FormRow><SectionText>Acceso solicitado a {provider.origin}</SectionText></FormRow>}
        {newAuthorization && <FormRow><SectionText>Introduce la credencial para autorizar este acceso.</SectionText></FormRow>}
        {changedAuthorization && <FormRow><SectionText problem>El alcance solicitado ha cambiado. Vuelve a introducir la credencial para autorizarlo.</SectionText></FormRow>}
        <FormRow>
          <Button disabled={busy || (!token.trim() && (!hasCredential || needsReconnect))} onClick={() => void connect()}>{hasCredential && !needsReconnect ? "Actualizar conexión" : "Conectar"}</Button>
          <span className="grow" />
          {hasCredential && <button className="connector-danger" type="button" disabled={busy} onClick={() => void disconnect()}>Desconectar</button>}
        </FormRow>
      </FormSection>}
      {!provider.credential && <FormSection header="Acceso del conector">
        <FormRow><SectionText>{provider.capability === "http" ? `Acceso solicitado a ${provider.origin ?? "origen no indicado"}` : `Acceso solicitado a la carpeta ${typeof configuration.folder === "string" && configuration.folder ? abbreviatedPath(configuration.folder, home) : "sin elegir"}`}</SectionText></FormRow>
        {scopeNeedsAuthorization && <FormRow><SectionText>{changedAuthorization || provider.capability === "folder" && account.folder !== configuration.folder ? "El alcance solicitado ha cambiado. Autorízalo antes de guardar." : "Autoriza este acceso antes de guardar."}</SectionText></FormRow>}
        {scopeNeedsAuthorization && <FormRow><Button disabled={busy || provider.capability === "folder" && !configuration.folder || acceptedScope === scopeKey} onClick={() => setAcceptedScope(scopeKey)}>{acceptedScope === scopeKey ? "Acceso autorizado para guardar" : "Autorizar acceso"}</Button></FormRow>}
      </FormSection>}
      {view && <ConnectorViewFields view={view} configuration={configuration} onChange={changeField} onAction={fieldAction} home={home} />}
      {(problem || visibleValidationProblem(validationIssue, configuration) || view?.problem) && <FormSection><FormRow><SectionText problem>{problem ?? visibleValidationProblem(validationIssue, configuration) ?? view?.problem}</SectionText></FormRow></FormSection>}
    </div>
    <SaveBar dirty={dirty} busy={busy} discard={discard} save={() => void save()} />
  </form>;
}
