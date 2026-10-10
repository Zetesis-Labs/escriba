import { z } from "./vendor/zod/index.js";
import type { Request, Host, Result, Note } from "./types.js";
export declare const notionSchema: z.ZodObject<{
    source: z.ZodObject<{
        id: z.ZodString;
        title: z.ZodDefault<z.ZodString>;
        databaseTitle: z.ZodDefault<z.ZodString>;
        properties: z.ZodArray<z.ZodObject<{
            name: z.ZodString;
            type: z.ZodString;
        }, z.core.$strip>>;
    }, z.core.$strip>;
    columns: z.ZodOptional<z.ZodRecord<z.ZodString, z.ZodString>>;
    body: z.ZodOptional<z.ZodString>;
    mapping: z.ZodOptional<z.ZodObject<{
        byField: z.ZodRecord<z.ZodString, z.ZodString>;
    }, z.core.$strip>>;
    template: z.ZodOptional<z.ZodObject<{
        blocks: z.ZodArray<z.ZodRecord<z.ZodString, z.ZodUnknown>>;
    }, z.core.$strip>>;
}, z.core.$strip>;
export declare function notionConfig(raw: unknown): {
    source: {
        id: string;
        title: string;
        databaseTitle: string;
        properties: {
            name: string;
            type: string;
        }[];
    };
    columns: Record<string, string>;
    body: string;
};
export declare function suggestedColumns(source: ReturnType<typeof notionConfig>["source"], existing?: Record<string, string>): Record<string, string>;
export declare function notionProblem(config: ReturnType<typeof notionConfig>): string | undefined;
type Block = {
    object: "block";
    type: string;
    [key: string]: unknown;
};
export declare function notionPayload(note: Note, config: ReturnType<typeof notionConfig>, audio?: string): {
    properties: Record<string, unknown>;
    children: Block[];
};
export declare function runNotion(request: Request, host: Host): Promise<Result>;
export {};
