export type CommandOrigin = "ui" | "shell";
export type CommandHandler = (
  params: Record<string, unknown>,
  origin: CommandOrigin,
) => Promise<unknown>;
export interface CommandRegistry {
  register(method: string, handler: CommandHandler): void;
  owns(method: string): boolean;
  dispatch(method: string, params: Record<string, unknown>, origin: CommandOrigin): Promise<unknown>;
}
export const isOrigin = (value: unknown): value is CommandOrigin =>
  value === "ui" || value === "shell";
export function createCommands(): CommandRegistry {
  const handlers = new Map<string, CommandHandler>();
  return {
    register(method, handler) {
      if (handlers.has(method)) throw Error(`Comando repetido: ${method}`);
      handlers.set(method, handler);
    },
    owns: (method) => handlers.has(method),
    async dispatch(method, params, origin) {
      const handler = handlers.get(method);
      if (!handler) throw Error(`Método desconocido: ${method}`);
      return handler(params, origin);
    },
  };
}
export function registerControllerCommands(
  commands: CommandRegistry,
  status: { dataPath: string },
) {
  commands.register("controller_status", async () => ({
    protocolVersion: 1,
    dataPath: status.dataPath,
  }));
}
