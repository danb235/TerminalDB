import { fileURLToPath, URL } from "node:url";

import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@terminaldb/protocol": fileURLToPath(
        new URL("../../packages/protocol/src/index.ts", import.meta.url),
      ),
      "@terminaldb/design-system/styles.css": fileURLToPath(
        new URL("../../packages/design-system/src/styles.css", import.meta.url),
      ),
    },
  },
  server: {
    port: 4173,
  },
  build: {
    target: "es2022",
    sourcemap: true,
  },
  test: {
    environment: "jsdom",
    exclude: ["tests/**", "**/node_modules/**", "**/dist/**"],
  },
});
