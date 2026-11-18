import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const sdks = fileURLToPath(new URL("..", import.meta.url));

export default defineConfig({
  root: fileURLToPath(new URL(".", import.meta.url)),
  oxc: { jsx: { runtime: "automatic" } },
  resolve: { dedupe: ["react", "react-dom"] },
  server: { port: 4173, strictPort: true, fs: { allow: [sdks] } },
  test: {
    include: ["test/**/*.test.{ts,tsx}"],
    environment: "happy-dom",
    restoreMocks: true,
  },
});
