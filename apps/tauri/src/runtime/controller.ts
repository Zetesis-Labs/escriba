import { z } from "zod";
import { builtinProviders, type ConnectorEditorRequest, type Provider } from "@escriba/conectores";
import { connectorEditor, accountHttp } from "./accounts";
import { accountAuthority, authorityKey, providerAccess, providerManifest } from "../core/providerAccess";
import type {
  Destination,
  Recording,
  Recipe,
  Resolver,
  Version,
  Transcript,
  Digest,
  JSONObject,
  JSONValue,
  ProcessOptions,
  JobState,
  NativeStatus,
} from "../types";
import {
  aborted,
  json,
  jsonObject,
  message,
  errorCode,
  RuntimeError,
  object,
  readContext,
  type RuntimeContext,
  request,
  text,
  type RuntimeHost,
  type RuntimeRunner,
} from "./contracts";
import { createConnectorService, currentVersion } from "./connectors";
import { summarizeText } from "./summary";
import { remember, summaryMemory } from "./memory";
import type { Lists } from "./defaultRecipe";
import { normalizeTranscriptionInputs, withCorrectionCriteria } from "../core/transcriptionMemory";
import {
  confirmedVersionId,
  materialized,
  noteView,
  openNote,
  transcriptionKey,
  transcriptionPlan,
  versionSaveParams,
  versionsView,
  versionUpdateParams,
  withData,
  withDigest,
  withTranscript,
  type WorkingNote,
} from "../core/workingNote";
import { notificationProblems } from "../core/notificationProblems";
import { recipeWithValues } from "../core/recipeValues";
import { processingRecipeId } from "../core/recordingRecipe";
import { manualSummaryReading, manualSummaryResolver } from "../core/manualSummary";
import { ontologyDependencies, ontologyRequirement } from "../core/ontologyDependencies";
import { localModel } from "./localModels";
import { builtinProgram } from "../core/builtinRecipes";
import { modelCall } from "../core/modelCall";
function lookup<T extends { id: string; name: string }>(
  values: T[],
  id: string,
  kind: string,
): T {
  const found = values.filter((v) => v.id === id || v.name === id);
  if (found.length !== 1) throw Error(`${kind} desconocido o ambiguo: ${id}`);
  return found[0];
}
function lists(snapshot: RuntimeContext): Lists {
  return {
    stts: snapshot.resolvers
      .filter((r) => r.role === "stt" && r.enabled)
      .map(resolver),
    llms: snapshot.resolvers
      .filter((r) => r.role === "llm" && r.enabled)
      .map(resolver),
    conectores: snapshot.destinations.map((d) => ({
      clave: d.id,
      nombre: d.name,
      tipo: d.provider,
      activo:
        d.enabled &&
        snapshot.accounts.some((a) => a.id === d.account && a.enabled),
    })),
    recetas: snapshot.recipes.map((r) => ({
      clave: r.id,
      nombre: r.name,
      tipo: r.kind === "form" ? "formulario" : "codigo",
    })),
    cuentas: snapshot.accounts.map((account) => ({
      clave: account.id,
      nombre: account.name,
      tipo: account.provider,
      activo: account.enabled,
      origen: account.origin ?? account.grant?.origin ?? null,
    })),
  };
}
const resolver = (r: Resolver) => ({
  clave: r.id,
  nombre: r.name,
  local: r.local,
  modelo: r.model || null,
  url: r.url || null,
});
// requisito-recetas.md: a recipe calling an LLM in a loop never runs out of CPU time.
const MAX_LLM_CALLS_PER_NOTE = 50;
function selected(
  snapshot: RuntimeContext,
  role: "stt" | "llm",
  id?: string,
): Resolver {
  const enabled = snapshot.resolvers.filter(
    (r) => r.role === role && r.enabled,
  );
  const value = id
    ? lookup(enabled, id, "Resolutor")
    : enabled.find((r) => r.local);
  if (!value) throw Error(`No hay resolutor ${role} disponible`);
  return value;
}
function recipeProgram(
  recipe: Recipe,
  snapshot: RuntimeContext,
): string | undefined {
  if (recipe.kind === "code") {
    if (!recipe.bundle)
      throw new RuntimeError(`La receta ${recipe.name} no tiene un paquete válido`, "recipe_unavailable");
    return recipe.bundle;
  }
  if (recipe.base) {
    const base = snapshot.recipes.find(
      (r) => r.id === recipe.base || r.name === recipe.base,
    );
    if (!base)
      throw new RuntimeError(`La receta base ${recipe.base} no está disponible`, "recipe_unavailable");
    if (!base.bundle)
      throw new RuntimeError(`La receta base ${base.name} no tiene un paquete válido`, "recipe_unavailable");
    return base.bundle;
  }
  return undefined;
}
function startingVersion(recording: Recording, baseVersionId: string | null | undefined): Version | undefined {
  if (baseVersionId === null) return undefined;
  if (baseVersionId === undefined) return recording.versions.length ? currentVersion(recording) : undefined;
  const found = recording.versions.find((version) => version.id === baseVersionId);
  if (!found) throw Error("La versión de partida ya no existe");
  return found;
}
export function createRuntime(
  host: RuntimeHost,
  runner: RuntimeRunner,
  options: { builtinProgram?: string } = {},
) {
  const jobs = new Map<string, { state: JobState; abort: AbortController }>();
  const subscribers = new Set<() => void>();
  const connectors = createConnectorService(
    host,
    runner,
    options.builtinProgram,
  );
  let projectQueue: Promise<void> = Promise.resolve();
  let nativeOwner: { id: string } | undefined;
  let nativeCancellation: Promise<unknown> = Promise.resolve();
  function cancelNative(id: string) {
    if (nativeOwner?.id !== id) return;
    nativeOwner = undefined;
    nativeCancellation = host.call("native_cancel").catch((error) => {
      if (error instanceof Error && error.name === "AbortError") return;
      return writeLog(id, message(error), "error");
    });
  }
  const notify = () => subscribers.forEach((fn) => fn());
  const stage = (id: string, name: string) => {
    const job = jobs.get(id);
    if (job) {
      job.state.stage = name;
      notify();
    }
  };
  async function runJob<T>(
    id: string,
    operation: (signal: AbortSignal) => Promise<T>,
  ): Promise<T> {
    if (jobs.has(id)) throw Error("La grabación ya se está procesando");
    const abort = new AbortController();
    jobs.set(id, {
      state: { recordingId: id, stage: "En cola", startedAt: Date.now() },
      abort,
    });
    notify();
    try {
      const cancellation = nativeCancellation;
      nativeCancellation = Promise.resolve();
      await cancellation;
      aborted(abort.signal);
      return await operation(abort.signal);
    } finally {
      jobs.delete(id);
      notify();
    }
  }
  async function writeLog(
    id: string,
    message: string,
    level = "info",
    recipeId?: string,
  ) {
    await host.call("log", { recordingId: id, message, level, recipeId });
  }
  async function processRecording(
    id: string,
    processOptions: ProcessOptions = {},
  ) {
    return runJob(id, async (signal) => {
      const snapshot = await readContext(host, id);
      const recording = snapshot.recordings.find((r) => r.id === id);
      if (!recording) throw Error("Grabación no encontrada");
      recording.versions = withCorrectionCriteria(recording.versions);
      if (!recording.audioPath)
        throw Error("La grabación no tiene copia de audio");
      if (recording.status === "discarded")
        throw Error("Restaura la grabación antes de procesarla");
      const requestedRecipe = processingRecipeId(
        processOptions,
        recording,
        snapshot.settings,
      );
      if (
        !snapshot.recipes.some(
          (recipe) =>
            recipe.id === requestedRecipe || recipe.name === requestedRecipe,
        )
      )
        throw new RuntimeError(`La receta ${requestedRecipe} no está disponible`, "recipe_unavailable");
      const chosen = lookup(snapshot.recipes, requestedRecipe, "Receta");
      const fresh = processOptions.force ?? true;
      let accountMutation = false;
      const recomputed = fresh && !processOptions.dryRun ? new Set<string>() : undefined;
      const retranscribed = fresh && !processOptions.dryRun ? new Set<string>() : undefined;
      const remembering = !processOptions.dryRun;
      let llmCalls = 0;
      const countLlmCall = () => {
        if (++llmCalls > MAX_LLM_CALLS_PER_NOTE)
          throw Error(`La receta llegó al tope de ${MAX_LLM_CALLS_PER_NOTE} llamadas a un LLM por nota`);
      };
      const base = startingVersion(recording, processOptions.baseVersionId);
      const notes = new Map<string, WorkingNote>();
      const opened = new Map<string, number>();
      let inCourse: WorkingNote | undefined;
      let confirmed: string | undefined;
      let ownsStatus = !recording.versions.length;
      const warnings: string[] = [];
      const traceStarted = new Date().toISOString();
      const traceSteps: {
        capability: string;
        origin: string;
        seconds: number;
        error?: string;
      }[] = [];
      let traceError: string | undefined;
      let traceErrorCode: ReturnType<typeof errorCode> | undefined;
      const warn = async (error: unknown, recipeId?: string) => {
        const value = message(error);
        warnings.push(value);
        await writeLog(id, value, "warn", recipeId);
      };
      const view = (note: WorkingNote) => noteView(note, recording);
      const open = (origin: Version | undefined, editing: boolean) => {
        const editingAlready = editing && [...notes.values()].find((note) => note.editing && note.origin?.id === origin?.id);
        if (editingAlready) return editingAlready;
        const prefix = origin?.id ?? "";
        const count = opened.get(prefix) ?? 0;
        opened.set(prefix, count + 1);
        const note = openNote(`nota-${notes.size + 1}`, `${prefix}#${count}`, origin, editing);
        notes.set(note.handle, note);
        return note;
      };
      const update = (note: WorkingNote) => {
        notes.set(note.handle, note);
        if (inCourse?.handle === note.handle) inCourse = note;
        return note;
      };
      const noteOf = (handle: unknown) => {
        aborted(signal);
        if (handle === undefined) return (inCourse ??= open(base, false));
        const note = notes.get(String(handle));
        if (!note) throw Error("La nota no pertenece a esta ejecución");
        return note;
      };
      const transcribed = (note: WorkingNote) => {
        if (!note.transcript) throw Error("La nota aún no está transcrita");
        return note;
      };
      const place = (version: Version) => {
        const index = recording.versions.findIndex((v) => v.id === version.id);
        if (index < 0) recording.versions.push(version);
        else recording.versions[index] = version;
      };
      const materialize = async (opened: WorkingNote, recipeId: string, transcriptChanged = false): Promise<WorkingNote> => {
        aborted(signal);
        if (processOptions.dryRun) {
          const note = update(materialized(opened, opened.versionId ?? `dry-${recording.versions.length}`));
          const { recordingId: _recording, select: _select, voicesFrom: _voices, job: _job, ...fields } = versionSaveParams(note, id, recipeId);
          place({ ...(fields as unknown as Version), id: note.versionId!, createdAt: new Date().toISOString() });
          return note;
        }
        const earlier = opened.versionId || !processOptions.jobId
          ? undefined
          : recording.versions.find((v) => v.job?.id === processOptions.jobId && v.job?.note === opened.key);
        const note = earlier ? update(materialized(opened, earlier.id)) : opened;
        if (note.versionId) {
          const updated = await request<Version | null>(host, "version_update", versionUpdateParams(note, id, note.versionId, transcriptChanged));
          const local = recording.versions.find((v) => v.id === note.versionId);
          place(updated ?? { ...(local as Version), transcript: note.transcript!, inputs: note.inputs, digest: note.digest ?? null, data: note.data ?? null });
          return note;
        }
        const saved = await request<Version>(host, "version_save", versionSaveParams(note, id, recipeId, processOptions.jobId));
        place(saved);
        return update(materialized(note, saved.id));
      };
      const execute = async (
        recipe: Recipe,
        chain: string[],
      ): Promise<void> => {
        if (chain.includes(recipe.id) || chain.length >= 16)
          throw Error("Las recetas forman un ciclo o superan 16 niveles");
        const program = recipeProgram(recipe, snapshot);
        const values: JSONObject = { ...recipe.values };
        if (!program && !("idioma" in values))
          values.idioma =
            snapshot.settings.language === "auto"
              ? null
              : snapshot.settings.language;
        if (processOptions.stt) values.stt = processOptions.stt;
        if (processOptions.llm) values.llm = processOptions.llm;
        if (processOptions.language !== undefined)
          values.idioma =
            processOptions.language === "auto" ? null : processOptions.language;
        if (processOptions.summarize !== undefined)
          values.resumir = processOptions.summarize;
        if (
          processOptions.diarize !== undefined ||
          processOptions.speakers !== undefined
        )
          values.hablantes = {
            ...object(values.hablantes || {}),
            ...(processOptions.diarize !== undefined
              ? { detectar: processOptions.diarize }
              : {}),
            ...(processOptions.speakers !== undefined
              ? { cuantos: processOptions.speakers }
              : {}),
          } as JSONObject;
        const monitored = new WeakSet<AbortSignal>();
        await runner.run(
          {
            kind: "recipe",
            program,
            payload: {
              ...(program ? {} : { builtin: builtinProgram(recipe) }),
              audio: {
                clave: id,
                nombre: recording.title,
                fecha: recording.createdAt,
                origen: null,
              },
              values,
              lists: lists(snapshot),
            },
          },
          {
            signal,
            timeoutMs: 10000,
            call: async (operation, raw, invocationSignal) => {
              const signal = invocationSignal || jobs.get(id)?.abort.signal;
              if (signal && !monitored.has(signal)) {
                monitored.add(signal);
                signal.addEventListener(
                  "abort",
                  () => {
                    cancelNative(id);
                  },
                  { once: true },
                );
              }
              aborted(signal);
              const args = object(raw);
              const step = {
                capability: operation,
                origin: recipe.id,
                seconds: 0,
                error: undefined as string | undefined,
              };
              const stepStarted = performance.now();
              try {
                switch (operation) {
                  case "graph.open":
                  case "graph.query":
                  case "graph.link": {
                    if (processOptions.dryRun)
                      throw Error("La prueba de receta no modifica el grafo; usa una nota de prueba para ejecutar esta receta");
                    const ontologyId = text(args.ontologyId, "ontología");
                    const dependency = ontologyRequirement(recipe, snapshot.recipes, ontologyId);
                    const params = { recipeId: recipe.id, recordingId: id, ontologyId, dependency };
                    if (operation === "graph.open") return await host.call("knowledge_open", params);
                    if (!Number.isSafeInteger(args.expectedVersion) || Number(args.expectedVersion) < 1)
                      throw Error("Versión de ontología inválida");
                    if (operation === "graph.link") {
                      if (ontologyId === "escriba")
                        throw Error("La base de Escriba ya deriva sus registros de la biblioteca; no se puede vincular una nota a ella");
                      const opened = transcribed(noteOf(args.noteId));
                      const note = opened.versionId ? opened : await materialize(update({ ...opened, changed: true }), recipe.id);
                      return await host.call("knowledge_link", {
                        ...params, expectedVersion: args.expectedVersion,
                        versionId: note.versionId, recordId: text(args.recordId, "registro"),
                      });
                    }
                    if (ontologyId !== "escriba" && !accountMutation) {
                      await host.call("account_effect_begin", { recordingId: id });
                      accountMutation = true;
                    }
                    return await host.call("knowledge_query", {
                      ...params, expectedVersion: args.expectedVersion,
                      sql: text(args.sql, "SurrealQL"), bindings: text(args.bindings, "parámetros"),
                    });
                  }
                  case "transcribe": {
                    const opened = noteOf(args.handle);
                    const backend = selected(
                      snapshot,
                      "stt",
                      typeof args.stt === "string" ? args.stt : undefined,
                    );
                    const speakers = object(args.hablantes || {});
                    if (speakers.detectar === true && !backend.local)
                      throw Error(
                        "La diarización solo está disponible con Whisper local",
                      );
                    const inputs: JSONObject = normalizeTranscriptionInputs({
                      audioHash: recording.audioHash || recording.id,
                      backend: backend.id,
                      model: backend.local
                        ? localModel(backend, snapshot.settings.whisperModel)
                        : backend.model || null,
                      language:
                        args.idioma === null || args.idioma === "auto"
                          ? null
                          : typeof args.idioma === "string"
                            ? args.idioma
                            : snapshot.settings.language === "auto"
                              ? null
                              : snapshot.settings.language,
                      diarize: speakers.detectar === true,
                      speakers:
                        typeof speakers.cuantos === "number"
                          ? speakers.cuantos
                          : null,
                    });
                    const plan = transcriptionPlan(opened, inputs, recording.versions, retranscribed);
                    if (plan.kind === "keep") return view(opened);
                    if (!ownsStatus && !processOptions.dryRun) {
                      ownsStatus = true;
                      await host.call("recording_update", { id, status: "processing", error: null });
                    }
                    let note: WorkingNote;
                    if (plan.kind === "reuse") {
                      stage(id, "Reutilizando transcripción");
                      note = update(withTranscript(opened, {
                        transcript: plan.version.transcript,
                        inputs,
                        backend: plan.version.backend,
                        hasVoices: plan.version.hasVoices === true,
                        voicesFrom: plan.version.id,
                      }));
                    } else {
                      stage(id, "Transcribiendo");
                      let transcript: Transcript;
                      const owner = { id };
                      nativeOwner = owner;
                      try {
                        transcript = await request<Transcript>(
                          host,
                          "transcribe",
                          {
                            recordingId: id,
                            resolverId: backend.id,
                            language: inputs.language,
                            diarize: inputs.diarize,
                            speakers: inputs.speakers,
                          },
                        );
                      } finally {
                        if (nativeOwner === owner) nativeOwner = undefined;
                      }
                      aborted(signal);
                      if (
                        typeof transcript?.text !== "string" ||
                        !Array.isArray(transcript.segments)
                      )
                        throw Error(
                          "El transcriptor devolvió una respuesta no válida",
                        );
                      note = update(withTranscript(opened, {
                        transcript,
                        inputs,
                        backend: backend.id,
                        hasVoices: inputs.diarize === true,
                        voicesFrom: null,
                      }));
                    }
                    retranscribed?.add(transcriptionKey(inputs));
                    return view(await materialize(note, recipe.id, true));
                  }
                  case "note": {
                    const editing = args.editar === true;
                    if (args.version === undefined || args.version === null) {
                      if (inCourse && editing && !inCourse.editing)
                        throw Error("La nota en curso es una copia; para editar una versión pídela por su clave");
                      return view((inCourse ??= open(base, editing)));
                    }
                    const origin = recording.versions.find((v) => v.id === args.version);
                    if (!origin) throw Error("La versión no pertenece a la grabación");
                    return view(open(origin, editing));
                  }
                  case "versions":
                    return versionsView(recording, base?.id);
                  case "summarize": {
                    const note = transcribed(noteOf(args.handle));
                    stage(id, "Resumiendo");
                    const model = selected(
                      snapshot,
                      "llm",
                      typeof args.llm === "string" ? args.llm : undefined,
                    );
                    const owner = { id };
                    nativeOwner = owner;
                    let digest: Digest;
                    try {
                      digest = await summarizeText(
                        summaryMemory(
                          host,
                          id,
                          remembering,
                          { resolver: model },
                          signal,
                          recomputed,
                        ),
                        note.transcript!.text,
                        model.id,
                        {
                          prompt:
                            typeof args.prompt === "string"
                              ? args.prompt
                              : undefined,
                          language:
                            typeof note.inputs?.language === "string"
                              ? note.inputs.language
                              : null,
                          capacity: model.local ? 3500 : 6000,
                          signal,
                        },
                      );
                    } finally {
                      if (nativeOwner === owner) nativeOwner = undefined;
                    }
                    aborted(signal);
                    return view(await materialize(update(withDigest(note, digest)), recipe.id));
                  }
                  case "save": {
                    const opened = transcribed(noteOf(args.handle));
                    const changed = "data" in args ? update(withData(opened, json(args.data))) : opened;
                    const note = changed !== opened || (changed.changed && !changed.versionId) ? await materialize(changed, recipe.id) : changed;
                    aborted(signal);
                    if (!note.changed) return view(note);
                    const target = note.versionId!;
                    if (!processOptions.dryRun)
                      await host.call("version_select", { recordingId: id, versionId: target });
                    recording.currentVersionId = target;
                    confirmed = target;
                    return view(note);
                  }
                  case "ask": {
                    countLlmCall();
                    const model = selected(
                      snapshot,
                      "llm",
                      typeof args.llm === "string" ? args.llm : undefined,
                    );
                    const prompt = text(args.entrada, "entrada");
                    stage(id, "Consultando");
                    const owner = { id };
                    nativeOwner = owner;
                    try {
                      const params = {
                        resolverId: model.id,
                        prompt,
                        instructions:
                          typeof args.instrucciones === "string"
                            ? args.instrucciones
                            : "",
                        ...(args.schema
                          ? { schema: jsonObject(args.schema) }
                          : {}),
                      };
                      const answer = await remember(
                        host,
                        id,
                        remembering,
                        {
                          kind: "ask",
                          resolver: model,
                          params,
                        },
                        async () => {
                          const value = await request<JSONValue>(
                            host,
                            "ask",
                            params,
                          );
                          if (params.schema)
                            z.fromJSONSchema(params.schema).parse(value);
                          else if (typeof value !== "string")
                            throw Error("El modelo no devolvió texto");
                          return value;
                        },
                        signal,
                        recomputed,
                      );
                      aborted(signal);
                      return answer;
                    } finally {
                      if (nativeOwner === owner) nativeOwner = undefined;
                    }
                  }
                  case "model": {
                    countLlmCall();
                    const model = selected(snapshot, "llm", text(args.llm, "llm"));
                    if (model.local) throw Error("escriba.modelo necesita un LLM remoto: el local no pasa por el AI SDK");
                    const call = modelCall({ method: args.method, options: args.options });
                    stage(id, "Consultando");
                    const answer = await remember(
                      host,
                      id,
                      remembering,
                      { kind: "model", resolver: model, params: call },
                      () => request<JSONValue>(host, "model_call", { resolverId: model.id, ...call }),
                      signal,
                      recomputed,
                    );
                    aborted(signal);
                    return answer;
                  }
                  case "publish": {
                    const note = noteOf(args.handle);
                    const published = recording.versions.find((v) => v.id === confirmedVersionId(note));
                    if (!published) throw Error("La nota aún no está transcrita");
                    const destination = lookup(
                      snapshot.destinations,
                      text(args.destinationId, "destino"),
                      "Destino",
                    );
                    stage(id, `Publicando en ${destination.name}`);
                    if (!processOptions.dryRun)
                      await connectors.publish(
                        id,
                        destination.id,
                        published,
                        signal,
                      );
                    return null;
                  }
                  case "account.http": {
                    const account = lookup(snapshot.accounts, text(args.accountId, "cuenta"), "Cuenta");
                    if (args.multipart !== undefined) throw Error("El SDK no tiene acceso a los adjuntos de la grabación");
                    return await accountHttp(host, account.id, args, {
                      expected: accountAuthority(account, snapshot.providers),
                      signal,
                      beforeSend: async (method) => {
                        if (["GET", "HEAD"].includes(method)) return;
                        if (processOptions.dryRun) throw Error("La prueba de receta no permite escrituras externas del SDK");
                        if (!accountMutation) {
                          await host.call("account_effect_begin", { recordingId: id });
                          accountMutation = true;
                        }
                      },
                    });
                  }
                  case "process": {
                    const next = lookup(
                      snapshot.recipes,
                      text(args.recipeId, "receta"),
                      "Receta",
                    );
                    await execute(next, [...chain, recipe.id]);
                    return null;
                  }
                  case "log": {
                    const content = text(args.message, "mensaje");
                    const level = ["warn", "error"].includes(String(args.level))
                      ? String(args.level)
                      : "info";
                    if (level === "warn" || level === "error")
                      warnings.push(content);
                    await writeLog(id, content, level, recipe.id);
                    return null;
                  }
                  default:
                    throw Error(
                      `Capacidad de receta no permitida: ${operation}`,
                    );
                }
              } catch (error) {
                step.error = message(error);
                throw error;
              } finally {
                step.seconds = (performance.now() - stepStarted) / 1000;
                traceSteps.push(step);
              }
            },
          },
        );
      };
      try {
        if (!processOptions.dryRun && recording.accountEffectPending) {
          if (processOptions.force === false) throw Error("Revisa la operación externa o sobre el grafo antes de reprocesar esta nota manualmente");
          await host.call("account_effect_finish", { recordingId: id });
        }
        if (!processOptions.dryRun && ownsStatus)
          await host.call("recording_update", {
            id,
            status: "processing",
            error: null,
          });
        await execute(recipeWithValues(chosen, processOptions.values), []);
        aborted(signal);
        if (!notes.size || !recording.versions.length) throw Error("La receta no produjo una transcripción");
        if (!processOptions.dryRun && ownsStatus)
          await host.call("recording_update", {
            id,
            status: "done",
            error: warnings.length ? warnings.join("\n") : null,
          });
        return { versionId: confirmed ?? (inCourse && confirmedVersionId(inCourse)) ?? currentVersion(recording).id };
      } catch (error) {
        if (accountMutation) error = new RuntimeError(`La receta hizo una operación externa o sobre el grafo; revisa el resultado antes de reprocesar. ${message(error)}`, "failed");
        traceError = message(error);
        traceErrorCode = errorCode(error);
        if (!processOptions.dryRun && ownsStatus)
          await host.call("recording_update", {
            id,
            status: signal.aborted ? "pending" : "failed",
            error: message(error),
          });
        await writeLog(id, message(error), "error", chosen.id);
        throw error;
      } finally {
        try {
          await host.call("trace_save", {
            recordingId: id,
            recipeId: chosen.id,
            dryRun: processOptions.dryRun === true,
            startedAt: traceStarted,
            finishedAt: new Date().toISOString(),
            steps: traceSteps,
            error: traceError || null,
            errorCode: traceErrorCode || null,
            result: inCourse?.transcript
              ? {
                  transcript: inCourse.transcript,
                  digest: inCourse.digest || null,
                  data: inCourse.data ?? null,
                }
              : null,
          });
        } catch (error) {
          if (traceError)
            throw new RuntimeError(`${traceError} · No se pudo guardar la traza: ${message(error)}`, traceErrorCode ?? "failed");
          throw error;
        }
      }
    });
  }
  async function summarizeRecording(id: string, llm?: string) {
    return runJob(id, async (signal) => {
      const snapshot = await readContext(host, id);
      const recording = snapshot.recordings.find((r) => r.id === id);
      if (!recording) throw Error("Grabación no encontrada");
      const version = currentVersion(recording);
      const reading = manualSummaryReading(snapshot.settings.defaultRecipeId, snapshot.recipes);
      const resolver = manualSummaryResolver(snapshot.resolvers, llm ?? reading.llm);
      if (!resolver) throw Error("No hay resolutor llm disponible");
      stage(id, "Resumiendo");
      const owner = { id };
      nativeOwner = owner;
      let digest: Digest;
      try {
        digest = await summarizeText(
          host,
          version.transcript.text,
          resolver.id,
          {
            signal,
            capacity: resolver.local ? 3500 : 6000,
            language: reading.language,
            prompt: reading.prompt,
          },
        );
      } finally {
        if (nativeOwner === owner) nativeOwner = undefined;
      }
      aborted(signal);
      await host.call("version_update", {
        recordingId: id,
        versionId: version.id,
        digest,
      });
      const latest = (await readContext(host, id)).recordings.find(
        (r) => r.id === id,
      );
      if (latest && currentVersion(latest).id === version.id) {
        for (const publication of latest.publications) {
          try {
            await connectors.publish(
              id,
              publication.destinationId,
              { ...version, digest },
              signal,
            );
          } catch (error) {
            await writeLog(
              id,
              `No se pudo actualizar ${publication.name}: ${message(error)}`,
              "warn",
            );
          }
        }
      }
    });
  }
  async function getRecipeSchema(recipeId: string): Promise<JSONObject | null> {
    const snapshot = await readContext(host);
    const recipe = lookup(snapshot.recipes, recipeId, "Receta");
    const program = recipeProgram(recipe, snapshot);
    const schema = await runner.run(
      {
        kind: "recipe-schema",
        program,
        payload: {
          ...(program ? {} : { builtin: builtinProgram(recipe) }),
          lists: lists(snapshot),
          defaultLanguage: snapshot.settings.language,
        },
      },
      {
        timeoutMs: 10000,
        call: async () => {
          throw Error("La inspección no tiene capacidades");
        },
      },
    );
    return schema === null ? null : jsonObject(schema);
  }
  return {
    connectorEditor: (operation: "describe" | "action" | "validate", input: ConnectorEditorRequest) => connectorEditor(host, runner, operation, input),
    async notificationProblems(status: NativeStatus) {
      return notificationProblems(await readContext(host), status);
    },
    processRecording,
    summarizeRecording,
    publishRecording: (id: string, destinationId: string) =>
      connectors.publish(id, destinationId),
    unpublishRecording: (id: string, destinationId: string) =>
      connectors.remove(id, destinationId),
    previewDestination: (destinationId: string, recordingId?: string) =>
      connectors.preview(destinationId, recordingId),
    discoverDestination: (destinationId: string) =>
      connectors.discover(destinationId),
    validateDestination: (destinationId: string) =>
      connectors.validate(destinationId),
    cancelProcessing(id: string) {
      const job = jobs.get(id);
      job?.abort.abort();
      cancelNative(id);
    },
    getJobs: () => [...jobs.values()].map((j) => ({ ...j.state })),
    subscribeJobs(listener: () => void) {
      subscribers.add(listener);
      return () => {
        subscribers.delete(listener);
      };
    },
    getRecipeSchema,
    rebuildProject(options: { loadOnly?: boolean } = {}) {
      const rebuilding = projectQueue.then(async () => {
        const snapshot = await readContext(host);
        const built = object(await host.call(options.loadOnly ? "shell.project_load" : "shell.project_build"));
        if (!Array.isArray(built.recipes))
          throw Error("El proyecto no devolvió recetas");
        const recipes: Recipe[] = built.recipes.map((raw) => {
          const entry = object(raw);
          const id = text(entry.id, "ID de receta");
          return {
            id,
            name: text(entry.name, "nombre de receta"),
            kind: "code",
            values: snapshot.recipes.find((r) => r.id === id)?.values || {},
            entry: text(entry.entry, "archivo de receta"),
            bundle: text(entry.bundle, "programa de receta"),
          };
        });
        const inspection = {
          timeoutMs: 10000,
          call: async () => {
            throw Error("La inspección no tiene capacidades");
          },
        };
        let destinations: Destination[] = [];
        let providers: Provider[] = [];
        let ontologies: unknown[] = [];
        if (typeof built.ontologyProgram === "string") {
          const inspected = object(await runner.run(
            { kind: "ontology-inspect", program: built.ontologyProgram, payload: {} }, inspection,
          ));
          if (!Array.isArray(inspected.ontologies)) throw Error("El proyecto no devolvió ontologías");
          ontologies = inspected.ontologies;
        }
        if (typeof built.connectorProgram === "string") {
          const program = built.connectorProgram;
          const inspected = object(
            await runner.run(
              { kind: "connector-inspect", program, payload: {} },
              inspection,
            ),
          );
          if (!Array.isArray(inspected.destinations))
            throw Error("El proyecto no devolvió destinos");
          if (inspected.providers !== undefined && !Array.isArray(inspected.providers)) throw Error("El proyecto devolvió proveedores inválidos");
          const ids = new Set<string>();
          providers = (Array.isArray(inspected.providers) ? inspected.providers : []).flatMap((raw) => {
            const provider = providerManifest(raw);
            if (ids.has(provider.id)) throw Error(`Proveedor repetido: ${provider.id}`);
            ids.add(provider.id);
            const builtin = builtinProviders.find((entry) => entry.id === provider.id);
            if (builtin) {
              if (authorityKey(providerAccess(builtin)) !== authorityKey(providerAccess(provider))) throw Error("El proyecto no puede cambiar los permisos de un proveedor de serie");
              return [];
            }
            return [{ ...provider, program }];
          });
          destinations = inspected.destinations.map((raw) => {
            const d = object(raw);
            const provider = text(d.provider, "proveedor");
            if (![...builtinProviders, ...providers].some((entry) => entry.id === provider))
              throw Error("Proveedor desconocido");
            const id = text(d.id, "ID de destino");
            const account = text(d.account, "cuenta del destino");
            if (
              !snapshot.accounts.some(
                (a) => a.id === account && a.provider === d.provider,
              )
            )
              throw Error(`Cuenta incompatible o inexistente: ${account}`);
            return {
              id,
              name: text(d.name, "nombre del destino"),
              provider,
              account,
              enabled:
                snapshot.destinations.find((previous) => previous.id === id)
                  ?.enabled ?? true,
              configuration: jsonObject(d.configuration),
              inputSchema: jsonObject(d.inputSchema || {}),
              ...(typeof d.description === "string"
                ? { description: d.description }
                : {}),
              program,
            };
          });
        }
        const catalog = {
          ...snapshot,
          recipes: [
            ...snapshot.recipes.filter((r) => r.kind === "form"),
            ...recipes,
          ],
          destinations,
          providers,
        };
        for (const recipe of recipes) {
          const inspected = object(
            await runner.run(
              {
                kind: "recipe-inspect",
                program: recipe.bundle,
                payload: { lists: lists(catalog) },
              },
              inspection,
            ),
          );
          recipe.schema = jsonObject(inspected.schema);
          recipe.ontologies = ontologyDependencies(inspected.ontologias);
          if (typeof inspected.name === "string" && inspected.name.trim())
            recipe.name = inspected.name;
          if (typeof inspected.description === "string")
            recipe.description = inspected.description;
          if (inspected.startsFrom === "note") recipe.startsFrom = "note";
        }
        await host.call("project_install", { recipes, destinations, providers, ontologies });
      });
      projectQueue = rebuilding.then(() => {}, () => {});
      return rebuilding;
    },
  };
}
