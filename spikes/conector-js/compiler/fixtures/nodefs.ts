import { readFileSync } from "node:fs";
export const result = readFileSync("/etc/passwd", "utf8");
