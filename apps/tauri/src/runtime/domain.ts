import { readdirSync, rmSync, statSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { builtinProviders } from "@escriba/conectores";
import type { CommandHandler, CommandOrigin, CommandRegistry } from "./commands";
import { json, message, object, RuntimeError, text, type RuntimeHost } from "./contracts";
import { SHELL_CONTROLLER_METHODS, UI_CONTROLLER_METHODS } from "./controllerMethods";
import type { CredentialStore } from "./credentials";
import { authorizedAccess, type HttpTransport } from "./http";
import { stageAudio } from "./library/audio";
import { durable, parseHistoryQuery, stampTrace } from "./library/jobs";
import { isObject, newId, type Json } from "./library/json";
import type { Library } from "./library/library";
import type { Queue } from "./library/queue";
import { validVoice } from "./library/voices";
import { notification, resolverProblem, settingsChanged, type Notification } from "./notifications";
import * as remote from "./remote";
import type { NativeStatus } from "../types";
import { missingLlm } from "./platform";
import { localModel } from "./localModels";
import { defaultLocalStt } from "../core/resolvers";

export interface Tasks {
  run<T>(id: string, recordingId: string | undefined, body: () => Promise<T>): Promise<T>;
  cancel(id: string): void;
  current(): string | undefined;
}
export interface DomainDependencies {
  library: Library;
  queue: Queue;
  host: RuntimeHost;
  credentials: CredentialStore;
  transport?: HttpTransport;
  tasks: Tasks;
  execute(operation: string, args: Record<string, unknown>): Promise<unknown>;
  notificationProblems(status: NativeStatus): Promise<unknown>;
  emit(event: string, value?: unknown): void;
  log(message: string): void;
}
const UI: readonly CommandOrigin[] = ["ui"];
const SHELL: readonly CommandOrigin[] = ["shell"];
const ANY: readonly CommandOrigin[] = ["ui", "shell"];
const AUDIO_TYPES: Record<string, string> = {
  mp3: "audio/mpeg",
  wav: "audio/wav",
  flac: "audio/flac",
  aac: "audio/aac",
  ogg: "audio/ogg",
  oga: "audio/ogg",
  opus: "audio/ogg",
  aif: "audio/aiff",
  aiff: "audio/aiff",
  caf: "audio/x-caf",
  webm: "audio/webm",
};
export const audioType = (path: string) => AUDIO_TYPES[extname(path).slice(1).toLowerCase()] ?? "audio/mp4";
const optionalText = (value: unknown) => (typeof value === "string" ? value : undefined);
export function projectAccounts(accounts: Json, destinations: Json): Json[] {
  if (!Array.isArray(accounts)) throw Error("Cuentas inválidas");
  if (!Array.isArray(destinations)) throw Error("Destinos inválidos");
  return accounts.filter(
    (account) =>
      !destinations.some(
        (destination) =>
          isObject(destination) &&
          isObject(account) &&
          destination.id === account.id &&
          destination.account === account.id &&
          (destination.program === undefined || destination.program === null),
      ),
  );
}
export async function notify(host: RuntimeHost, notice: Notification) {
  await host.call("shell.notify", { ...notice });
}
export async function warnAboutUnusable(deps: Pick<DomainDependencies, "library" | "host" | "notificationProblems" | "log">) {
  const model = deps.library.index().settings.whisperModel ?? null;
  let status: Record<string, unknown>;
  try {
    status = object(await deps.host.call("shell.native", { method: "status", params: { model } }));
  } catch (error) {
    deps.log(message(error));
    await notify(deps.host, notification({ kind: "backendUnavailable", reason: message(error) }));
    return;
  }
  const whisper = object(status.whisper ?? {});
  const llm = object(status.llm ?? {});
  const problems = await deps.notificationProblems({
    protocolVersion: status.protocolVersion,
    whisper: { available: whisper.available },
    llm: { available: llm.available, reason: llm.reason },
  } as NativeStatus);
  if (!Array.isArray(problems)) throw Error("No se pudieron leer los avisos de los resolutores");
  for (const problem of problems) {
    deps.log(text(object(problem).reason, "motivo"));
    await notify(deps.host, resolverProblem(problem));
  }
}
function fromInbox(library: Library, inbox: string, source: string, recovered = false) {
  const staged = stageAudio(library.root, inbox, recovered);
  return { ...staged, source };
}
function fallbackStt(library: Library) {
  const resolvers = library.index().resolvers;
  const local = defaultLocalStt(Array.isArray(resolvers) ? resolvers.filter(isObject) : []);
  if (!local) throw new RuntimeError("No queda ningún Whisper local: añade uno en STT", "backend_unavailable");
  return text(local.id, "id");
}
async function inference(deps: DomainDependencies, method: "transcribe" | "summarize" | "ask", p: Record<string, unknown>) {
  const { library, host, credentials } = deps;
  const transport = deps.transport ?? fetch;
  const key = optionalText(p.resolverId) ?? (method === "transcribe" ? fallbackStt(library) : "local-llm");
  const missing = missingLlm(key);
  if (missing) throw Error(missing);
  const resolver = library.item("resolvers", key);
  if (resolver.enabled === false) throw Error("El resolutor está apagado");
  const secret = async () => (await credentials.read(key))?.trim();
  if (method === "transcribe") {
    const recordingId = text(p.recordingId, "recordingId");
    const audio = library.audio(recordingId);
    const transcript =
      resolver.local === true
        ? await host.call("shell.native", { method: "transcribe", params: { ...p, audioPath: audio, model: localModel({ ...resolver, id: key }, library.index().settings.whisperModel) } })
        : await remote.transcribe(resolver, await secret(), audio, { language: p.language, diarize: p.diarize }, transport);
    return library.recognizeTranscription(recordingId, json(transcript));
  }
  if (resolver.local === true) return host.call("shell.native", { method, params: p });
  const schema = method === "summarize" ? remote.digestSchema() : p.schema;
  return remote.ask(resolver, await secret(), { instructions: p.instructions, prompt: p.prompt, ...(schema === undefined ? {} : { schema }) }, transport);
}
export function registerDomainCommands(commands: CommandRegistry, deps: DomainDependencies) {
  const { library, queue, host, tasks, emit } = deps;
  const settings = () => library.index().settings;
  const write =
    (event: "changed" | "log", handler: CommandHandler): CommandHandler =>
    async (p, origin) => {
      const result = await handler(p, origin);
      emit(event);
      if (event === "changed") queue.wakeAll();
      return result;
    };
  const named = (name: string, origins: readonly CommandOrigin[], event: "changed" | "log" | undefined, handler: CommandHandler) =>
    commands.register(name, origins, event ? write(event, handler) : handler);
  const mutation = (name: string, origins: readonly CommandOrigin[]) =>
    named(name, origins, name === "log" ? "log" : "changed", (p) => library.mutate(name, json(p)));
  const reviewResolvers = (name: string, p: Record<string, unknown>) => {
    if (!settingsChanged(name, p)) return;
    void warnAboutUnusable(deps).catch((error) => deps.log(message(error)));
  };
  async function cancelRecording(recordingId: string) {
    const cancellation = await queue.cancel(recordingId);
    if (cancellation.inference) await host.call("shell.native_cancel").catch((error) => deps.log(message(error)));
    for (const id of cancellation.ids) tasks.cancel(id);
  }
  named("snapshot", UI, undefined, () => library.snapshot());
  named("library", UI, undefined, async () => library.libraryView());
  named("recording_detail", ANY, undefined, (p) => library.recording(text(p.id, "id")));
  named("runtime_context", ANY, undefined, (p) => library.runtimeContext(optionalText(p.recordingId)));
  named("runtime_run", UI, undefined, async (p) => {
    const operation = text(p.operation, "operation");
    const args = object(p.args ?? {});
    if (durable(operation)) return queue.wait(await queue.enqueue(operation, json(args)));
    return tasks.run(newId(), optionalText(args.recordingId), () => deps.execute(operation, args));
  });
  named("runtime_jobs", UI, undefined, async () => queue.visible());
  named("runtime_history", UI, undefined, (p) => queue.history(parseHistoryQuery(p)));
  named("runtime_cancel", UI, undefined, async (p) => {
    await cancelRecording(text(p.recordingId, "recordingId"));
    return null;
  });
  named("runtime_relaunch", UI, "changed", async (p) => ({ id: await queue.relaunch(text(p.id, "id")) }));
  named("runtime_job_steps", UI, undefined, (p) => library.jobSteps(text(p.id, "id")));
  mutation("log", ANY);
  named("log_list", UI, undefined, (p) => library.logList(json(p)));
  named("memory_recall", ANY, undefined, async (p) => (await library.memoryRecall(text(p.recordingId, "recordingId"), text(p.fingerprint, "fingerprint"))) ?? null);
  named("memory_keep", ANY, undefined, async (p) => {
    await library.memoryKeep(text(p.recordingId, "recordingId"), text(p.fingerprint, "fingerprint"), json(p.value ?? null));
    return null;
  });
  named("trace_save", ANY, "changed", async (p) => {
    const task = tasks.current();
    await library.traceSave(task === undefined ? json(p) : stampTrace("trace_save", json(p), task));
    return null;
  });
  named("trace_list", UI, undefined, (p) => library.traceList(optionalText(p.recordingId)));
  mutation("account_effect_begin", ANY);
  mutation("account_effect_finish", ANY);
  mutation("recording_update", ANY);
  named("recording_discard", UI, "changed", async (p) => {
    await cancelRecording(text(p.id, "id"));
    return library.mutate("recording_discard", json(p));
  });
  named("recording_remove_audio", UI, "changed", (p) => library.removeAudio(json(p), (_, id) => library.busy(id)));
  for (const name of ["version_save", "version_select", "version_update", "publication_save", "publication_remove"]) mutation(name, ANY);
  for (const name of ["version_delete", "version_keep_only"] as const) named(name, UI, "changed", (p) => library.removeVersions(name, json(p)));
  for (const name of ["note_draft_get", "note_draft_begin", "note_draft_save", "note_draft_discard", "note_draft_commit"]) mutation(name, UI);
  for (const name of ["config_save", "config_remove"])
    named(name, UI, "changed", async (p) => {
      const saved = await library.mutate(name, json(p));
      reviewResolvers(name, p);
      return saved;
    });
  named("settings_save", ANY, "changed", async (p) => {
    const changes = object(p.settings ?? {});
    if (typeof changes.launchAtLogin === "boolean") await host.call("shell.autolaunch", { enabled: changes.launchAtLogin });
    const saved = await library.mutate("settings_save", json(p));
    emit("settings");
    reviewResolvers("settings_save", p);
    return saved;
  });
  named("people_list", UI, undefined, () => library.people());
  named("people_set_color", UI, "changed", async (p) => {
    await library.setPersonColor(text(p.name, "name"), text(p.color, "color"));
    return null;
  });
  named("people_rename", UI, "changed", async (p) => {
    await library.renamePerson(text(p.name, "name"), text(p.newName, "newName"));
    return null;
  });
  named("people_remove", UI, "changed", async (p) => {
    await library.removePerson(text(p.name, "name"));
    return null;
  });
  named("people_remove_voice", UI, "changed", async (p) => {
    await library.removePersonVoice(text(p.id, "id"));
    return null;
  });
  named("people_add_voice", SHELL, "changed", async (p) => {
    const voice = json(p.voice);
    if (!validVoice(voice)) throw Error("Huella de voz inválida");
    await library.addPersonVoice(text(p.name, "name"), voice, text(p.source, "source"));
    return null;
  });
  named("connector_save", UI, "changed", async (p) => {
    await library.saveConnector(json(p.account ?? null), json(p.destination ?? null));
    reviewResolvers("connector_save", p);
    return null;
  });
  named("connector_remove", UI, "changed", async (p) => {
    await library.removeConnector(text(p.id, "id"));
    reviewResolvers("connector_remove", p);
    return null;
  });
  named("connector_files", ANY, undefined, async (p) => {
    const account = library.item("accounts", text(p.accountId, "accountId"));
    const providerId = account.provider;
    if (typeof providerId !== "string") throw Error("Cuenta sin proveedor");
    const provider = builtinProviders.some((entry) => entry.id === providerId) ? undefined : library.item("providers", providerId);
    authorizedAccess(account, provider, p, "folder");
    return host.call("shell.files", { account, request: p });
  });
  named("connector_audio", ANY, undefined, async (p) => {
    const recordingId = text(p.recordingId, "recordingId");
    const record = await library.recording(recordingId);
    if (record.audioPath === null || record.audioPath === undefined) return null;
    const path = library.audio(recordingId);
    return { size: statSync(path).size, type: audioType(path), filename: basename(path) };
  });
  for (const name of ["transcribe", "summarize", "ask"] as const) named(name, ANY, name === "transcribe" ? "changed" : undefined, (p) => inference(deps, name, p));
  named("native_cancel", ANY, undefined, () => host.call("shell.native_cancel"));
  named("project_install", ANY, "changed", async (p) => {
    await library.install(json(p), (ontologies) => host.call("shell.validate_catalog", { ontologies }).then(() => undefined));
    return null;
  });
  named("okf_file", UI, undefined, (p) => host.call("shell.okf_file", { account: library.item("accounts", text(p.accountId, "accountId")), path: text(p.path, "path"), action: text(p.action, "action") }));
  named("settings_read", SHELL, undefined, async () => library.settingsJson());
  named("recipe_name", SHELL, undefined, async (p) => {
    const recipes = library.index().recipes;
    const found = Array.isArray(recipes) ? recipes.find((entry) => isObject(entry) && entry.id === p.id) : undefined;
    return isObject(found) && typeof found.name === "string" ? found.name : null;
  });
  named("project_context", SHELL, undefined, async () => {
    const index = library.index();
    return { path: index.settings.projectPath ?? null, accounts: projectAccounts(index.accounts, index.destinations) };
  });
  named("import_inbox", SHELL, "changed", async (p) => {
    if (!Array.isArray(p.files)) throw Error("Faltan los audios");
    const recipeId = optionalText(p.recipeId);
    const imported: Json[] = [];
    for (const entry of p.files) {
      const file = object(entry);
      const inbox = text(file.inbox, "inbox");
      const source = text(file.source, "source");
      try {
        imported.push(await library.importStaged(fromInbox(library, inbox, source), source, recipeId));
      } finally {
        rmSync(inbox, { force: true });
      }
    }
    return imported;
  });
  named("recording_recorded", SHELL, "changed", async (p) => {
    const path = text(p.path, "path");
    const record = await library.importRecorded(fromInbox(library, path, path), path, optionalText(p.recipeId), { duration: json(p.duration ?? null), createdAt: json(p.createdAt ?? null) });
    try {
      rmSync(path);
    } catch (error) {
      throw Error(`Audio guardado; no se pudo retirar la captura temporal: ${message(error)}`);
    }
    return record;
  });
  named("captures_recover", SHELL, "changed", async () => {
    const root = join(library.root, "captures");
    let recovered = 0;
    for (const entry of readdirSync(root, { withFileTypes: true })) {
      if (!entry.isFile() || extname(entry.name) !== ".m4a") continue;
      const path = join(root, entry.name);
      if (statSync(path).size === 0) continue;
      try {
        const record = object(await library.importStaged(fromInbox(library, path, path, true), path));
        await library.mutate("log", { level: "warn", recordingId: text(record.id, "id"), message: "Recuperada una captura pendiente de guardar" });
        rmSync(path);
        recovered++;
      } catch (error) {
        deps.log(`No se pudo recuperar ${path}: ${message(error)}`);
      }
    }
    return recovered;
  });
  named("watch_folders", SHELL, undefined, async () => ({ folders: settings().watchedFolders ?? [], bookmarks: library.watchedFolderBookmarks() }));
  named("watch_incorporate", SHELL, "changed", async (p) => {
    const inbox = text(p.inbox, "inbox");
    const source = text(p.source, "source");
    const startedAt = new Date(text(p.startedAt, "startedAt"));
    if (Number.isNaN(startedAt.getTime())) throw Error("Fecha de grabación inválida");
    try {
      return await library.importWatched(fromInbox(library, inbox, source), source, text(p.title, "title"), startedAt, text(p.sourceKey, "sourceKey"));
    } finally {
      rmSync(inbox, { force: true });
    }
  });
  mutation("recording_abandoned", SHELL);
  named("watch_folder_save", SHELL, "changed", (p) =>
    library.authorizeWatchedFolder(optionalText(p.folderId), text(p.path, "path"), optionalText(p.name), text(p.style, "style"), bytes(p.bookmark)),
  );
  named("watch_folder_refresh", SHELL, "changed", (p) =>
    library.refreshWatchedFolderBookmark(text(p.folderId, "folderId"), bytes(p.previous), text(p.resolved, "resolved"), p.replacement === undefined || p.replacement === null ? undefined : bytes(p.replacement)),
  );
  named("watch_seed_voice_memos", SHELL, "changed", (p) => library.seedVoiceMemos(text(p.root, "root")));
  named("knowledge_ontologies", SHELL, undefined, async () => settings().projectOntologies ?? []);
  named("knowledge_context", SHELL, undefined, async (p) => {
    const index = library.index();
    let recipe = library.item("recipes", text(p.recipeId, "recipeId"));
    if (recipe.kind === "form") {
      const base = recipe.base;
      const found = Array.isArray(index.recipes) ? index.recipes.find((entry) => isObject(entry) && (entry.id === base || entry.name === base)) : undefined;
      if (!isObject(found)) throw Error("Receta base no disponible");
      recipe = found;
    }
    const recording = index.recordings.find((entry) => entry.id === p.recordingId);
    return { recipe, recording: recording ? { id: recording.id, status: recording.status } : null };
  });
  named("knowledge_feed_prepare", SHELL, undefined, async (p) => {
    await library.knowledgePrepare(text(p.epoch, "epoch"));
    return null;
  });
  named("knowledge_feed_changes", SHELL, undefined, (p) => library.knowledgeChanges(typeof p.limit === "number" ? p.limit : 1));
  named("knowledge_feed_ack", SHELL, undefined, async (p) => {
    if (!Array.isArray(p.acks)) throw Error("Faltan los acuses");
    for (const ack of p.acks) {
      const entry = object(ack);
      await library.knowledgeAck(text(entry.key, "key"), text(entry.revision, "revision"));
    }
    return null;
  });
  for (const name of [...UI_CONTROLLER_METHODS, ...SHELL_CONTROLLER_METHODS]) if (!commands.owns(name)) throw Error(`Falta el comando ${name}`);
}
function bytes(value: unknown): number[] {
  if (!Array.isArray(value) || !value.every((item) => Number.isInteger(item) && item >= 0 && item <= 255)) throw Error("Marcador de carpeta inválido");
  return value as number[];
}
