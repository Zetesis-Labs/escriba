import { z } from "zod";
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
} from "../types";
import {
  aborted,
  json,
  jsonObject,
  message,
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
import { reusableTranscription, transcriptionCriteriaKey } from "../core/transcriptionMemory";
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
  };
}
const resolver = (r: Resolver) => ({
  clave: r.id,
  nombre: r.name,
  local: r.local,
  modelo: r.model || null,
  url: r.url || null,
});
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
      throw Error(
        `RECIPE_UNAVAILABLE: La receta ${recipe.name} no tiene un paquete válido`,
      );
    return recipe.bundle;
  }
  if (recipe.base) {
    const base = snapshot.recipes.find(
      (r) => r.id === recipe.base || r.name === recipe.base,
    );
    if (!base)
      throw Error(
        `RECIPE_UNAVAILABLE: La receta base ${recipe.base} no está disponible`,
      );
    if (!base.bundle)
      throw Error(
        `RECIPE_UNAVAILABLE: La receta base ${base.name} no tiene un paquete válido`,
      );
    return base.bundle;
  }
  return undefined;
}
function recipeNote(version: Version, recording: Recording) {
  const transcript = version.transcript;
  return {
    handle: version.id,
    clave: recording.id,
    version: recording.versions.findIndex((v) => v.id === version.id) + 1,
    texto: transcript.text,
    hablantes: [
      ...new Set(transcript.segments.map((s) => s.speaker).filter(Boolean)),
    ],
    segmentos: transcript.segments.map((s) => ({
      inicio: s.start,
      fin: s.end,
      texto: s.text,
      hablante: s.speaker || null,
      palabras: (s.words || []).map((w) => ({
        inicio: w.start,
        fin: w.end,
        texto: w.text,
      })),
    })),
    resumen: version.digest
      ? {
          titulo: version.digest.title,
          texto: version.digest.summary,
          etiquetas: version.digest.tags,
        }
      : null,
    datos: version.data ?? null,
  };
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
  let queue: Promise<unknown> = Promise.resolve();
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
  async function runJob(
    id: string,
    operation: (signal: AbortSignal) => Promise<void>,
  ) {
    if (jobs.has(id)) throw Error("La grabación ya se está procesando");
    const abort = new AbortController();
    jobs.set(id, {
      state: { recordingId: id, stage: "En cola", startedAt: Date.now() },
      abort,
    });
    notify();
    const work = queue
      .catch(() => {})
      .then(async () => {
        const cancellation = nativeCancellation;
        nativeCancellation = Promise.resolve();
        await cancellation;
        aborted(abort.signal);
        await operation(abort.signal);
      });
    queue = work;
    try {
      await work;
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
      if (!recording.audioPath)
        throw Error("La grabación no tiene copia de audio");
      if (recording.status === "discarded")
        throw Error("Restaura la grabación antes de procesarla");
      const requestedRecipe =
        processOptions.recipeId ||
        recording.recipeId ||
        snapshot.settings.defaultRecipeId;
      if (
        !snapshot.recipes.some(
          (recipe) =>
            recipe.id === requestedRecipe || recipe.name === requestedRecipe,
        )
      )
        throw Error(
          `RECIPE_UNAVAILABLE: La receta ${requestedRecipe} no está disponible`,
        );
      const chosen = lookup(
        snapshot.recipes,
        processOptions.recipeId ||
          recording.recipeId ||
          snapshot.settings.defaultRecipeId,
        "Receta",
      );
      const fresh = processOptions.force ?? true;
      const renewed = new Set<string>();
      let current: Version | undefined;
      let savedData: JSONValue | undefined;
      const warnings: string[] = [];
      const traceStarted = new Date().toISOString();
      const traceSteps: {
        capability: string;
        origin: string;
        seconds: number;
        error?: string;
      }[] = [];
      let traceError: string | undefined;
      const warn = async (error: unknown, recipeId?: string) => {
        const value = message(error);
        warnings.push(value);
        await writeLog(id, value, "warn", recipeId);
      };
      const active = () => {
        aborted(signal);
        if (!current) throw Error("Primero transcribe la grabación");
        return current;
      };
      const keep = async (version: Version) => {
        current = version;
        const index = recording.versions.findIndex((v) => v.id === version.id);
        if (index < 0) recording.versions.push(version);
        else recording.versions[index] = version;
      };
      const persist = async (
        transcript: Transcript,
        backend: string,
        inputs: JSONObject,
        recipeId: string,
        sourceVersionId?: string,
      ) => {
        if (processOptions.dryRun) {
          const version: Version = {
            id: `dry-${recording.versions.length}`,
            createdAt: new Date().toISOString(),
            backend,
            recipeId,
            transcript,
            inputs,
          };
          await keep(version);
          return version;
        }
        aborted(signal);
        const version = await request<Version>(host, "version_save", {
          recordingId: id,
          transcript,
          backend,
          recipeId,
          inputs,
          ...(sourceVersionId ? { sourceVersionId } : {}),
        });
        await keep(version);
        return version;
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
                  case "transcribe": {
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
                    const inputs: JSONObject = {
                      audioHash: recording.audioHash || recording.id,
                      backend: backend.id,
                      model: backend.local
                        ? snapshot.settings.whisperModel
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
                    };
                    const key = transcriptionCriteriaKey(inputs);
                    const remembered = [...recording.versions]
                      .reverse()
                      .find((v) => reusableTranscription(v, inputs));
                    const newVersion = fresh && !renewed.has(key);
                    if (remembered && !newVersion) {
                      await keep({
                        ...remembered,
                        ...(savedData !== undefined ? { data: savedData } : {}),
                      });
                      return recipeNote(active(), recording);
                    }
                    stage(
                      id,
                      remembered
                        ? "Reutilizando transcripción"
                        : "Transcribiendo",
                    );
                    let transcript = remembered?.transcript;
                    if (!transcript) {
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
                    }
                    renewed.add(key);
                    const version = await persist(
                      transcript,
                      backend.id,
                      inputs,
                      recipe.id,
                      remembered?.id,
                    );
                    if (savedData !== undefined) version.data = savedData;
                    return recipeNote(version, recording);
                  }
                  case "summarize": {
                    const version = active();
                    if (args.handle !== undefined && args.handle !== version.id)
                      throw Error("La nota ya no es la versión activa");
                    stage(id, "Resumiendo");
                    const model = selected(
                      snapshot,
                      "llm",
                      typeof args.llm === "string" ? args.llm : undefined,
                    );
                    const owner = { id };
                    nativeOwner = owner;
                    try {
                      version.digest = await summarizeText(
                        summaryMemory(
                          host,
                          id,
                          processOptions.dryRun ? undefined : version.id,
                          { resolver: model },
                          signal,
                        ),
                        version.transcript.text,
                        model.id,
                        {
                          prompt:
                            typeof args.prompt === "string"
                              ? args.prompt
                              : undefined,
                          language:
                            typeof version.inputs?.language === "string"
                              ? version.inputs.language
                              : null,
                          capacity: model.local ? 3500 : 6000,
                          signal,
                        },
                      );
                    } finally {
                      if (nativeOwner === owner) nativeOwner = undefined;
                    }
                    aborted(signal);
                    if (!processOptions.dryRun)
                      await host.call("version_update", {
                        recordingId: id,
                        versionId: version.id,
                        digest: version.digest,
                      });
                    return recipeNote(version, recording);
                  }
                  case "save": {
                    const version = active();
                    if (args.handle !== undefined && args.handle !== version.id)
                      throw Error("La nota ya no es la versión activa");
                    if ("data" in args) {
                      savedData = json(args.data);
                      version.data = savedData;
                    }
                    aborted(signal);
                    if (!processOptions.dryRun) {
                      await host.call("version_update", {
                        recordingId: id,
                        versionId: version.id,
                        ...(savedData !== undefined ? { data: savedData } : {}),
                      });
                      await host.call("version_select", {
                        recordingId: id,
                        versionId: version.id,
                      });
                    }
                    return recipeNote(version, recording);
                  }
                  case "ask": {
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
                        processOptions.dryRun ? undefined : current?.id,
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
                      );
                      aborted(signal);
                      return answer;
                    } finally {
                      if (nativeOwner === owner) nativeOwner = undefined;
                    }
                  }
                  case "publish": {
                    if (
                      args.handle !== undefined &&
                      args.handle !== active().id
                    )
                      throw Error("La nota ya no es la versión activa");
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
                        active(),
                        signal,
                      );
                    return null;
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
        if (!processOptions.dryRun)
          await host.call("recording_update", {
            id,
            status: "processing",
            error: null,
            recipeId: chosen.id,
          });
        await execute(chosen, []);
        aborted(signal);
        if (!current) throw Error("La receta no produjo una transcripción");
        if (!processOptions.dryRun)
          await host.call("recording_update", {
            id,
            status: "done",
            error: warnings.length ? warnings.join("\n") : null,
          });
      } catch (error) {
        traceError = message(error);
        if (!processOptions.dryRun)
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
            result: current
              ? {
                  transcript: current.transcript,
                  digest: current.digest || null,
                  data: current.data ?? null,
                }
              : null,
          });
        } catch (error) {
          if (traceError)
            throw Error(
              `${traceError} · No se pudo guardar la traza: ${message(error)}`,
            );
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
      const resolver = selected(snapshot, "llm", llm);
      stage(id, "Resumiendo");
      const owner = { id };
      nativeOwner = owner;
      let digest: Digest;
      try {
        digest = await summarizeText(
          summaryMemory(host, id, version.id, { resolver }, signal),
          version.transcript.text,
          resolver.id,
          {
            signal,
            capacity: resolver.local ? 3500 : 6000,
            language: snapshot.settings.language,
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
  async function getRecipeSchema(recipeId: string): Promise<JSONObject> {
    const snapshot = await readContext(host);
    const recipe = lookup(snapshot.recipes, recipeId, "Receta");
    return jsonObject(
      await runner.run(
        {
          kind: "recipe-schema",
          program: recipeProgram(recipe, snapshot),
          payload: {
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
      ),
    );
  }
  return {
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
    async rebuildProject() {
      const snapshot = await readContext(host);
      const built = object(await host.call("project_build"));
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
        destinations = inspected.destinations.map((raw) => {
          const d = object(raw);
          if (d.provider !== "notion" && d.provider !== "okf")
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
            provider: d.provider,
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
        if (typeof inspected.name === "string" && inspected.name.trim())
          recipe.name = inspected.name;
        if (typeof inspected.description === "string")
          recipe.description = inspected.description;
      }
      await host.call("project_install", { recipes, destinations });
    },
  };
}
