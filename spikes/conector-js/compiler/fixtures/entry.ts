// Throwaway resolver fixture: public subpath plus a nested transitive package.
import { z } from "zod/v4";
import { answer } from "@fixture/parent";

export const result = z.object({ answer: z.number() }).parse({ answer });
export async function run() { return result; }
