import { builtinProviders, type ConnectorEditorRequest, type ConnectorEditorResult, type ProviderAccess, type Provider } from "@escriba/conectores";
import { accountAuthority, authorityKey } from "../core/providerAccess";
import { connectorEditorResult } from "./connectorView";
import { aborted, object, readContext, text, type RuntimeHost, type RuntimeRunner } from "./contracts";

export async function authorizedAccount(host: RuntimeHost, accountId: string, expected?: ProviderAccess, retained = false) {
  const snapshot = await readContext(host);
  const account = snapshot.accounts.find((entry) => entry.id === accountId);
  if (!account) throw Error("La cuenta no existe");
  const grant = accountAuthority(account, snapshot.providers, retained);
  if (expected && authorityKey(grant) !== authorityKey(expected)) throw Error("Los permisos de la cuenta han cambiado");
  return { account, grant };
}

export async function accountHttp(host: RuntimeHost, accountId: string, raw: unknown, options: {
  expected?: ProviderAccess;
  signal?: AbortSignal;
  retained?: boolean;
  beforeSend?: (method: string) => Promise<void>;
} = {}) {
  aborted(options.signal);
  const { grant } = await authorizedAccount(host, accountId, options.expected, options.retained);
  if (grant.capability !== "http" || !grant.origin) throw Error("La cuenta no permite HTTP");
  const args = object(raw);
  const url = new URL(text(args.url, "URL"));
  if (url.origin !== new URL(grant.origin).origin || url.username || url.password) throw Error("URL fuera de la cuenta");
  const method = String(args.method || "GET").toUpperCase();
  if (!["GET", "POST", "PATCH", "PUT", "DELETE", "HEAD"].includes(method)) throw Error("Método HTTP no permitido");
  const headers = object(args.headers || {});
  const allowed = grant.allowedHeaders.map((header) => header.toLowerCase());
  if (Object.keys(headers).some((header) => !allowed.includes(header.toLowerCase()) || header.toLowerCase() === grant.credential?.header.toLowerCase())) throw Error("Cabecera HTTP no permitida");
  await options.beforeSend?.(method);
  aborted(options.signal);
  return host.call("connector_http", {
    accountId,
    expectedGrant: grant,
    url: url.href,
    method,
    headers,
    body: args.body,
    ...(args.multipart === undefined ? {} : { multipart: args.multipart }),
  });
}

export async function connectorEditor(host: RuntimeHost, runner: RuntimeRunner, operation: "describe" | "action" | "validate", input: ConnectorEditorRequest): Promise<ConnectorEditorResult> {
  if (!["describe", "action", "validate"].includes(operation)) throw Error("Operación de editor no permitida");
  const snapshot = await readContext(host);
  const provider: Provider | undefined = builtinProviders.find((entry) => entry.id === input.providerId)
    ?? snapshot.providers?.find((entry) => entry.id === input.providerId);
  if (!provider || ("unavailable" in provider && provider.unavailable)) throw Error("El proveedor no está disponible");
  const account = snapshot.accounts.find((entry) => entry.id === input.accountId);
  if (account && account.provider !== provider.id) throw Error("La cuenta pertenece a otro proveedor");
  const grant = account && operation === "action" ? accountAuthority(account, snapshot.providers) : undefined;
  const result = await runner.run({
    kind: "connector",
    ...(provider.program ? { program: provider.program } : {}),
    payload: { operation, provider: provider.id, config: input.configuration, state: input.state ?? {}, action: input.action, value: input.value },
  }, {
    timeoutMs: 10000,
    call: async (capability, args, signal) => {
      if (operation !== "action" || !account) throw Error("La descripción no tiene capacidades externas");
      if (capability !== "connector.http") throw Error("Esta acción solo permite consultas HTTP de la cuenta");
      return accountHttp(host, account.id, args, { expected: grant, signal });
    },
  });
  return connectorEditorResult(result);
}
