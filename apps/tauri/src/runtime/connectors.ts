import type {
  Destination,
  Publication,
  Recording,
  Version,
  JSONObject,
} from "../types";
import { publicationConfiguration } from "../core/publicationConfiguration";
import { accountAuthority } from "../core/providerAccess";
import { authorizedAccount, accountHttp } from "./accounts";
import {
  aborted,
  jsonObject,
  object,
  readContext,
  request,
  text,
  type RuntimeHost,
  type RuntimeRunner,
} from "./contracts";
export function currentVersion(recording: Recording): Version {
  const version =
    recording.versions.find((v) => v.id === recording.currentVersionId) ||
    recording.versions.at(-1);
  if (!version) throw Error("Primero transcribe la grabación");
  return version;
}
export function connectorNote(recording: Recording, version: Version) {
  return {
    key: recording.id,
    startedAt: recording.createdAt,
    text: version.transcript.text,
    segments: version.transcript.segments,
    digest: version.digest || null,
    source: `urn:escriba:recording:${encodeURIComponent(recording.id)}`,
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
  };
}
export function createConnectorService(
  host: RuntimeHost,
  runner: RuntimeRunner,
  builtinProgram?: string,
) {
  const locks = new Map<string, Promise<unknown>>();
  async function locked<T>(key: string, work: () => Promise<T>): Promise<T> {
    const previous = locks.get(key) || Promise.resolve();
    const next = previous.catch(() => {}).then(work);
    locks.set(key, next);
    try {
      return await next;
    } finally {
      if (locks.get(key) === next) locks.delete(key);
    }
  }
  async function perform(
    operation: "publish" | "remove" | "preview" | "discover" | "validate",
    destinationId: string,
    recordingId?: string,
    version?: Version,
    signal?: AbortSignal,
    alreadyLocked = false,
  ): Promise<JSONObject> {
    const snapshot = await readContext(host, recordingId);
    const recording = recordingId
      ? snapshot.recordings.find((r) => r.id === recordingId)
      : undefined;
    if (recordingId && !recording) throw Error("Grabación no encontrada");
    const publication = recording?.publications.find(
      (p) => p.destinationId === destinationId,
    );
    if (operation === "remove" && !publication)
      throw Error("No hay publicación que retirar");
    const live = snapshot.destinations.find((d) => d.id === destinationId);
    const freshPreparation =
      operation === "publish" &&
      live &&
      publication?.receipt.state === "prepared" &&
      !publication.receipt.locator;
    const retained =
      publication &&
      !freshPreparation &&
      (operation === "publish" || operation === "remove");
    if (!live && !retained) throw Error("Destino no encontrado");
    const accountId = retained
      ? publication.accountId || live?.account
      : live?.account;
    if (!accountId) throw Error("La publicación no conserva su cuenta");
    const account = snapshot.accounts.find((a) => a.id === accountId);
    if (!account?.enabled) throw Error("La cuenta está desactivada o revocada");
    if (operation === "publish" && !retained && !live?.enabled)
      throw Error("El destino está desactivado");
    const configuration = publicationConfiguration(operation, live, retained ? publication : undefined);
    const program = retained
      ? publication.program || builtinProgram
      : live?.program || builtinProgram;
    const provider = retained ? publication.provider : live!.provider;
    if (account.provider !== provider) throw Error("La cuenta pertenece a otro proveedor");
    const name = retained ? publication.name : live!.name;
    const managed = retained ? publication.managed : live?.managed;
    const grant = accountAuthority(account, snapshot.providers, !!retained);
    if (!alreadyLocked)
      return locked(accountId, () =>
        perform(operation, destinationId, recordingId, version, signal, true),
      );
    return (async () => {
      aborted(signal);
      let receipt = publication?.receipt;
      const saving = operation === "publish" || operation === "remove";
      const save = async (next: unknown) => {
        if (!recording) throw Error("Falta grabación");
        receipt = jsonObject(next);
        await host.call("publication_save", {
          recordingId: recording.id,
          destinationId,
          name,
          provider,
          accountId,
          receipt,
          configuration,
          program,
          managed: managed === true,
        });
      };
      const refreshAuthority = async () => {
        aborted(signal);
        const { account: active } = await authorizedAccount(host, accountId, grant, !!retained);
        if (
          !active?.enabled ||
          active.folder !== account.folder ||
          active.origin !== account.origin
        )
          throw Error("La cuenta o sus permisos han cambiado");
      };
      if (saving && receipt?.state === "running" && !receipt.locator)
        throw Error(
          "Publicación incierta; reconcilia el destino antes de crear otra",
        );
      if (saving && (!receipt || freshPreparation))
        await save({ state: "prepared" });
      const result = await runner.run(
        {
          kind: "connector",
          program,
          payload: {
            operation,
            provider,
            config: configuration,
            ...(!managed && (live?.program ||
            (publication?.program && publication.program !== builtinProgram))
              ? { destination: destinationId }
              : {}),
            ...(recording && operation !== "remove"
              ? {
                  note: connectorNote(
                    recording,
                    version || currentVersion(recording),
                  ),
                }
              : {}),
            ...(receipt && receipt.state !== "prepared"
              ? { previous: receipt }
              : {}),
            now: new Date().toISOString(),
          },
        },
        {
          signal,
          timeoutMs: 10000,
          call: async (op, raw, invocationSignal) => {
            await refreshAuthority();
            aborted(invocationSignal);
            const args = object(raw);
            switch (op) {
              case "connector.http": {
                if (!saving && operation !== "discover") throw Error("Esta operación no permite acceso HTTP");
                const multipart = Array.isArray(args.multipart)
                  ? args.multipart.map((part) => {
                      const p = object(part);
                      if (p.audio) {
                        if (!recording) throw Error("No hay audio autorizado");
                        const a = object(p.audio);
                        return {
                          ...p,
                          audio: {
                            recordingId: recording.id,
                            start: a.start,
                            end: a.end,
                          },
                        };
                      }
                      return p;
                    })
                  : undefined;
                return accountHttp(host, accountId, {
                  ...args,
                  ...(multipart ? { multipart } : {}),
                }, {
                  expected: grant,
                  retained: !!retained,
                  signal: invocationSignal ?? signal,
                  beforeSend: async () => {
                    if (saving && receipt?.state === "prepared") await save({ ...receipt, state: "running" });
                  },
                });
              }
              case "connector.snapshot":
                if (grant.capability !== "folder")
                  throw Error("La cuenta no permite archivos");
                return host.call("connector_files", {
                  accountId,
                  expectedGrant: grant,
                  operation: "snapshot",
                });
              case "connector.apply":
                if (
                  !saving ||
                  grant.capability !== "folder" ||
                  !Array.isArray(args.changes)
                )
                  throw Error("Escritura no autorizada");
                if (receipt?.state === "prepared")
                  await save({ ...receipt, state: "running" });
                return host.call("connector_files", {
                  accountId,
                  expectedGrant: grant,
                  operation: "apply",
                  changes: args.changes,
                });
              case "connector.audio":
                if (!recording || !saving) throw Error("Audio no autorizado");
                return host.call("connector_audio", {
                  recordingId: recording.id,
                });
              case "connector.checkpoint":
                if (!saving) throw Error("Checkpoint no autorizado");
                await save(args.receipt);
                return null;
              default:
                throw Error(`Capacidad de conector no permitida: ${op}`);
            }
          },
        },
      );
      aborted(signal);
      const output = object(result);
      if (saving) {
        if (!output.receipt) throw Error("El conector no devolvió un recibo");
        await save(output.receipt);
        if (operation === "remove")
          await host.call("publication_remove", { recordingId, destinationId });
      }
      return jsonObject(output);
    })();
  }
  return {
    publish: (
      id: string,
      destination: string,
      version?: Version,
      signal?: AbortSignal,
    ) => perform("publish", destination, id, version, signal),
    remove: (id: string, destination: string, signal?: AbortSignal) =>
      perform("remove", destination, id, undefined, signal),
    preview: (destination: string, id?: string) =>
      perform("preview", destination, id),
    discover: (destination: string) => perform("discover", destination),
    validate: (destination: string) => perform("validate", destination),
  };
}
