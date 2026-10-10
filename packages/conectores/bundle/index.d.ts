import { z } from "./vendor/zod/index.js";
import type { Request, Host, Result } from "./types.js";
export * from "./types.js";
export { notionConfig, notionSchema, notionProblem, suggestedColumns } from "./notion.js";
export { okfConfig, okfSchema, standardDocuments } from "./okf.js";
export declare function run(request: Request, host?: Host): Promise<Result>;
export interface DestinationOptions {
    id: string;
    name: string;
    account: string;
    configuration: Record<string, unknown>;
    inputSchema?: z.ZodType;
    description?: string;
    prepare?: (input: unknown, request: Request) => Request["note"] | Promise<Request["note"]>;
}
export interface Destination extends DestinationOptions {
    provider: "notion" | "okf";
}
export declare function defineNotionDestination(options: DestinationOptions): Destination;
export declare function defineOKFDestination(options: DestinationOptions): Destination;
export declare function createProgram(destinations: Destination[]): {
    inspect(): {
        destinations: {
            description?: string | undefined;
            id: string;
            name: string;
            provider: "okf" | "notion";
            account: string;
            configuration: Record<string, unknown>;
            inputSchema: z.core.ZodStandardJSONSchemaPayload<z.ZodType<unknown, unknown, z.core.$ZodTypeInternals<unknown, unknown>>>;
        }[];
    };
    run(request: Request, host?: Host): Promise<Result>;
};
