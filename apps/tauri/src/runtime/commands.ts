import { builtinProviders } from "@escriba/conectores";
import { object, readContext, text, type RuntimeHost } from "./contracts";
import type { CredentialStore } from "./credentials";
import { authorizedAccess, httpWithGrant, type AudioFile, type HttpTransport } from "./http";
import * as remote from "./remote";
import { publicReply } from "./library/voices";

export type CommandOrigin = "ui" | "shell";
export type CommandHandler = (params: Record<string, unknown>, origin: CommandOrigin) => Promise<unknown>;
export interface CommandRegistry {
  register(method: string, origins: readonly CommandOrigin[], handler: CommandHandler): void;
  owns(method: string): boolean;
  dispatch(method: string, params: Record<string, unknown>, origin: CommandOrigin): Promise<unknown>;
}
export const isOrigin = (value: unknown): value is CommandOrigin => value === "ui" || value === "shell";
export function createCommands(): CommandRegistry {
  const handlers = new Map<string, { origins: readonly CommandOrigin[]; handler: CommandHandler }>();
  return {
    register(method, origins, handler) {
      if (handlers.has(method)) throw Error(`Comando repetido: ${method}`);
      handlers.set(method, { origins, handler });
    },
    owns: (method) => handlers.has(method),
    async dispatch(method, params, origin) {
      const entry = handlers.get(method);
      if (!entry) throw Error(`Método desconocido: ${method}`);
      if (!entry.origins.includes(origin)) throw Error(`Origen no permitido para ${method}`);
      return publicReply(await entry.handler(params, origin));
    },
  };
}
export interface ControllerDependencies {
  host: RuntimeHost;
  dataPath: string;
  credentials: CredentialStore;
  transport?: HttpTransport;
  audioPath(recordingId: string): string;
  emit(event: string, value?: unknown): void;
}
const UI: readonly CommandOrigin[] = ["ui"];
const ANY: readonly CommandOrigin[] = ["ui", "shell"];
function optionalText(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}
async function storedSecret(credentials: CredentialStore, params: Record<string, unknown>) {
  const typed = optionalText(params.key)?.trim();
  if (typed) return typed;
  const id = optionalText(params.resolverId);
  return id ? (await credentials.read(id))?.trim() : undefined;
}
function resolverFrom(params: Record<string, unknown>) {
  return object(params.resolver);
}
export function registerControllerCommands(commands: CommandRegistry, deps: ControllerDependencies) {
  const { host, credentials, emit } = deps;
  const transport = deps.transport ?? fetch;
  commands.register("controller_status", UI, async () => ({ protocolVersion: 1, dataPath: deps.dataPath }));
  commands.register("credential_save", UI, async (params) => {
    const id = text(params.id, "id");
    if (typeof params.value !== "string") throw Error("Falta la credencial");
    const context = await readContext(host);
    const known = context.accounts.some((account) => account.id === id) || context.resolvers.some((resolver) => resolver.id === id);
    if (!known) throw Error("La cuenta no existe");
    await credentials.save(id, params.value);
    emit("changed");
    return null;
  });
  commands.register("connector_http", ANY, async (params) => {
    const accountId = text(params.accountId, "accountId");
    const context = await readContext(host);
    const account = context.accounts.find((entry) => entry.id === accountId);
    if (!account) throw Error("La cuenta no existe");
    const providerId = account.provider;
    let provider: Record<string, unknown> | undefined;
    if (!builtinProviders.some((entry) => entry.id === providerId)) {
      const installed = context.providers?.find((entry) => entry.id === providerId);
      if (!installed) throw Error("Cuenta sin proveedor");
      provider = installed as unknown as Record<string, unknown>;
    }
    const grant = authorizedAccess(account as unknown as Record<string, unknown>, provider, params, "http");
    const secret = (await credentials.read(accountId))?.trim();
    let audio: AudioFile | undefined;
    const parts = Array.isArray(params.multipart) ? params.multipart : [];
    const reference = parts.map((part) => (part && typeof part === "object" ? (part as { audio?: unknown }).audio : undefined)).find((value) => value !== undefined);
    if (reference !== undefined) {
      const recordingId = text(object(reference).recordingId, "recordingId");
      audio = { path: deps.audioPath(recordingId), recordingId };
    }
    return httpWithGrant(account as unknown as Record<string, unknown>, grant, secret, params, audio, transport);
  });
  commands.register("resolver_models", UI, async (params) =>
    remote.models(resolverFrom(params), await storedSecret(credentials, params), transport),
  );
  commands.register("resolver_try", UI, async (params) => {
    const resolver = resolverFrom(params);
    const llm = text(params.role, "role") === "llm";
    const request = { instructions: params.instructions, prompt: params.prompt };
    if (resolver.local === true) {
      if (!llm) throw Error("Whisper en este Mac no tiene prueba");
      return host.call("shell.native", { method: "summarize", params: request });
    }
    const secret = await storedSecret(credentials, params);
    if (llm) return remote.ask(resolver, secret, { ...request, schema: remote.digestSchema() }, transport);
    return { text: await remote.probeTranscription(resolver, secret, transport) };
  });
}
