import type { Host, Result } from "./types.js";
import type { Configuration, ConnectorEditorResult } from "./protocol.js";
export declare const notionDefaultConfiguration: Configuration;
export declare const okfDefaultConfiguration: Configuration;
type Preview = (provider: string, config: Configuration) => Promise<Result>;
export declare function describeBuiltin(provider: string, config: Configuration, state: Configuration, preview: Preview): Promise<ConnectorEditorResult>;
export declare function actionBuiltin(provider: string, config: Configuration, state: Configuration, action: string, value: unknown, preview: Preview, host?: Host): Promise<ConnectorEditorResult>;
export declare function builtinProblem(provider: string, config: Configuration): string | undefined;
export {};
