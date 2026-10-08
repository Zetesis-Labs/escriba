import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true, host: "127.0.0.1" },
  resolve: {
    alias: {
      "@escriba/conectores": fileURLToPath(
        new URL("../../packages/conectores/src/index.ts", import.meta.url),
      ),
      zod: fileURLToPath(
        new URL("./node_modules/zod/index.js", import.meta.url),
      ),
      "@notionhq/client": fileURLToPath(
        new URL(
          "./node_modules/@notionhq/client/build/src/index.js",
          import.meta.url,
        ),
      ),
      "@noble/hashes": fileURLToPath(
        new URL("./node_modules/@noble/hashes", import.meta.url),
      ),
    },
  },
  worker: { format: "es" },
  build: { target: "es2022" },
  test: { include: ["tests/**/*.test.ts"], environment: "node" },
});
