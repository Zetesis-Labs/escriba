import { z } from "./vendor/zod/index.js";
import type { Request, Host, Result } from "./types.js";
declare const document: z.ZodObject<{
    id: z.ZodString;
    name: z.ZodString;
    path: z.ZodString;
    properties: z.ZodArray<z.ZodObject<{
        id: z.ZodOptional<z.ZodString>;
        key: z.ZodString;
        value: z.ZodString;
    }, z.core.$strip>>;
    body: z.ZodString;
}, z.core.$strip>;
export declare const okfSchema: z.ZodObject<{
    folder: z.ZodString;
    documents: z.ZodOptional<z.ZodArray<z.ZodObject<{
        id: z.ZodString;
        name: z.ZodString;
        path: z.ZodString;
        properties: z.ZodArray<z.ZodObject<{
            id: z.ZodOptional<z.ZodString>;
            key: z.ZodString;
            value: z.ZodString;
        }, z.core.$strip>>;
        body: z.ZodString;
    }, z.core.$strip>>>;
    producer: z.ZodOptional<z.ZodString>;
}, z.core.$strip>;
type Document = z.infer<typeof document>;
export declare function standardDocuments(): Document[];
export declare function okfConfig(config: unknown): {
    documents: {
        id: string;
        name: string;
        path: string;
        properties: {
            key: string;
            value: string;
            id?: string | undefined;
        }[];
        body: string;
    }[];
    folder: string;
    producer?: string | undefined;
};
export declare function runOKF(request: Request, host: Host): Promise<Result>;
export {};
