import type { Request, Host, Result } from "./types.js";
import type { Configuration, ProviderManifest, ConnectorEditorResult } from "./protocol.js";
export * from "./types.js";
export * from "./protocol.js";
export { notionConfig, notionSchema, notionProblem, suggestedColumns } from "./notion.js";
export { okfConfig, okfSchema, standardDocuments } from "./okf.js";
export declare const builtinProviders: ProviderManifest[];
export interface ConfigurationSchema {
    parse(value: unknown): unknown;
    safeParse(value: unknown): {
        success: true;
        data: unknown;
    } | {
        success: false;
        error: {
            issues: Array<{
                path: PropertyKey[];
                message: string;
            }>;
        };
    };
    toJSONSchema(): unknown;
}
export interface ProviderDefinition {
    manifest: ProviderManifest;
    configurationSchema: ConfigurationSchema;
    describe: (configuration: Configuration, state: Configuration) => ConnectorEditorResult | Promise<ConnectorEditorResult>;
    action?: (configuration: Configuration, state: Configuration, action: string, value: unknown, host?: Host) => ConnectorEditorResult | Promise<ConnectorEditorResult>;
    run?: (request: Request, host?: Host) => Result | Promise<Result>;
}
export declare function defineProvider(definition: ProviderDefinition): ProviderDefinition;
export declare function run(request: Request, host?: Host): Promise<Result>;
export interface DestinationOptions {
    id: string;
    name: string;
    account: string;
    configuration: Record<string, unknown>;
    inputSchema?: ConfigurationSchema;
    description?: string;
    prepare?: (input: unknown, request: Request) => Request["note"] | Promise<Request["note"]>;
}
export interface Destination extends DestinationOptions {
    provider: string;
}
export declare function defineNotionDestination(options: DestinationOptions): Destination;
export declare function defineOKFDestination(options: DestinationOptions): Destination;
export declare function createProgram(destinations: Destination[], providers?: ProviderDefinition[]): {
    inspect(): {
        providers: ProviderManifest[];
        destinations: {
            description?: string | undefined;
            id: string;
            name: string;
            provider: string;
            account: string;
            configuration: Record<string, unknown>;
            inputSchema: unknown;
        }[];
    };
    run(request: Request, host?: Host): Promise<Result>;
};
