import {
  CborCodec,
  Publisher,
  RpcEngine,
  Surreal,
  type ConnectionState,
  type DriverContext,
  type EngineEvents,
  type RequestOptions,
  type RpcRequest,
  type SurrealEngine,
} from "surrealdb";

type GraphCall = (operation: string, payload: unknown) => Promise<unknown>;

function encodeBase64(value: unknown): string {
  const bytes = CborCodec.DEFAULT.encode(value);
  let encoded = "";
  for (let offset = 0; offset < bytes.length; offset += 24576) {
    const chunk = bytes.subarray(offset, offset + 24576);
    encoded += btoa(String.fromCharCode(...chunk));
  }
  return encoded;
}

function decodeBase64(value: string): unknown {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++)
    bytes[index] = binary.charCodeAt(index);
  return CborCodec.DEFAULT.decode(bytes);
}

class GraphEngine extends RpcEngine implements SurrealEngine {
  readonly features = new Set<never>();
  readonly #events = new Publisher<EngineEvents>();

  constructor(
    context: DriverContext,
    private readonly ontologyId: string,
    private readonly expectedVersion: number,
    private readonly call: GraphCall,
  ) {
    super(context);
  }

  subscribe<K extends keyof EngineEvents>(
    event: K,
    listener: (...payload: EngineEvents[K]) => void,
  ): () => void {
    return this.#events.subscribe(event, listener);
  }

  open(state: ConnectionState): void {
    this._state = state;
    queueMicrotask(() => this.#events.publish("connected"));
  }

  async close(): Promise<void> {
    this._state = undefined;
    this.#events.publish("disconnected");
  }

  ready(version?: string): void {
    this._version = version;
  }

  async *liveQuery(): AsyncIterable<never> {
    throw Error("Las consultas en vivo no están disponibles para recetas");
  }

  async send<Method extends string, Params extends unknown[] | undefined, Result>(
    request: RpcRequest<Method, Params>,
    _options?: RequestOptions,
  ): Promise<Result> {
    if (request.method === "version") return "3.3.2" as Result;
    if (request.method === "health") return undefined as Result;
    if (request.method === "use") {
      const [namespace, database] = request.params ?? [];
      if (namespace !== "escriba" || database !== "graph")
        throw Error("La conexión del grafo tiene un ámbito fijo");
      return { namespace, database } as Result;
    }
    if (request.method === "query") {
      const [sql, bindings] = request.params ?? [];
      if (typeof sql !== "string" || !bindings || typeof bindings !== "object")
        throw Error("Consulta de grafo no válida");
      const response = await this.call("graph.query", {
        ontologyId: this.ontologyId,
        expectedVersion: this.expectedVersion,
        sql,
        bindings: encodeBase64(bindings),
      });
      if (typeof response !== "string")
        throw Error("Respuesta de grafo no válida");
      const statements = decodeBase64(response);
      if (!Array.isArray(statements))
        throw Error("Respuesta de grafo no válida");
      return statements.map((result) => ({
        time: "0s",
        status: "OK",
        type: "other",
        result,
      })) as Result;
    }
    throw Error(`Operación del SDK no disponible para recetas: ${request.method}`);
  }
}

export async function graphVersion(ontologyId: string, call: GraphCall): Promise<number> {
  if (typeof ontologyId !== "string" || !ontologyId.trim())
    throw Error("Falta el identificador de la ontología");
  const opened = await call("graph.open", { ontologyId });
  const version = (opened as { version?: unknown } | null)?.version;
  if (typeof version !== "number" || !Number.isSafeInteger(version) || version < 1)
    throw Error("La versión de la ontología no es válida");
  return version;
}

export async function openGraph(ontologyId: string, call: GraphCall): Promise<Surreal> {
  const version = await graphVersion(ontologyId, call);
  const db = new Surreal({
    engines: {
      escriba: (context) => new GraphEngine(context, ontologyId, version, call),
    },
  });
  await db.connect("escriba://graph", {
    namespace: "escriba",
    database: "graph",
    reconnect: false,
  });
  return db;
}
