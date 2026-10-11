import { builtinProviders, type Configuration, type ConnectorEditorRequest, type Provider, type ProviderAccess } from "@escriba/conectores";
import type { Account, JSONValue } from "../types";
import { authorityKey, providerAccess } from "./providerAccess";

export function availableProviders(installed: Provider[] = []): Provider[] {
  const byId = new Map<string, Provider>();
  for (const provider of builtinProviders) byId.set(provider.id, provider);
  for (const provider of installed) byId.set(provider.id, provider);
  return [...byId.values()];
}

export { providerAccess } from "./providerAccess";

export function editorRequest(providerId: string, account: Account | undefined, configuration: Configuration, state: Configuration): ConnectorEditorRequest {
  return { providerId, accountId: account?.id, configuration, state };
}

export interface ConnectorDraft {
  name: string;
  enabled: boolean;
  configuration: Configuration;
}

export function connectorDraftDirty(saved: ConnectorDraft, draft: ConnectorDraft, token: string, scopeAccepted: boolean): boolean {
  return saved.name !== draft.name || saved.enabled !== draft.enabled
    || JSON.stringify(saved.configuration) !== JSON.stringify(draft.configuration)
    || !!token.trim() || scopeAccepted;
}

export function reconcileConnectorDraft(previous: ConnectorDraft, draft: ConnectorDraft, saved: ConnectorDraft): ConnectorDraft {
  return {
    name: draft.name === previous.name ? saved.name : draft.name,
    enabled: draft.enabled === previous.enabled ? saved.enabled : draft.enabled,
    configuration: JSON.stringify(draft.configuration) === JSON.stringify(previous.configuration) ? saved.configuration : draft.configuration,
  };
}

export function accessChanged(saved: ProviderAccess | undefined, requested: ProviderAccess): boolean {
  if (!saved) return false;
  return authorityKey(saved) !== authorityKey(requested);
}

export function scopeAuthorizationKey(provider: Provider, configuration: Configuration): string {
  return JSON.stringify({ authority: authorityKey(providerAccess(provider)), folder: provider.capability === "folder" ? configuration.folder ?? "" : null });
}

export function needsScopeAuthorization(provider: Provider, account: Account, configuration: Configuration): boolean {
  if (provider.credential) return false;
  const ungranted = !account.grant && !builtinProviders.some((entry) => entry.id === provider.id);
  return ungranted || accessChanged(account.grant, providerAccess(provider))
    || (provider.capability === "folder" && account.folder !== configuration.folder);
}

export interface ValidationIssue {
  configuration: string;
  message: string;
}

export function visibleValidationProblem(issue: ValidationIssue | null, configuration: Configuration): string | null {
  return issue?.configuration === JSON.stringify(configuration) ? issue.message : null;
}

export function isSafeFieldPath(path: Array<string | number>): boolean {
  return path.length <= 32 && path.every((part) => typeof part === "number"
    ? Number.isSafeInteger(part) && part >= 0 && part < 10_000
    : part !== "__proto__" && part !== "prototype" && part !== "constructor");
}

export function fieldValue(configuration: Configuration, path: Array<string | number>): JSONValue | undefined {
  if (!isSafeFieldPath(path)) return undefined;
  let current: JSONValue | undefined = configuration;
  for (const part of path) {
    if (current === null || typeof current !== "object") return undefined;
    current = (current as Record<string | number, JSONValue>)[part];
  }
  return current;
}

export function setFieldValue(configuration: Configuration, path: Array<string | number>, value: JSONValue): Configuration {
  if (!isSafeFieldPath(path)) throw Error("Ruta de campo no válida");
  if (!path.length) return configuration;
  function replace(current: JSONValue | undefined, remaining: Array<string | number>): JSONValue {
    if (!remaining.length) return value;
    const [part, ...rest] = remaining;
    const container: JSONValue = Array.isArray(current) ? [...current] : current && typeof current === "object" ? { ...current } : typeof part === "number" ? [] : {};
    (container as Record<string | number, JSONValue>)[part] = replace((container as Record<string | number, JSONValue>)[part], rest);
    return container;
  }
  return replace(configuration, path) as Configuration;
}
