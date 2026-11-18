import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const sdks = fileURLToPath(new URL("..", import.meta.url));

export default defineConfig({
  root: fileURLToPath(new URL(".", import.meta.url)),
  resolve: { dedupe: ["react", "react-dom", "react-dom/client"] },
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  server: { port: 4174, strictPort: true, fs: { allow: [sdks] } },
  build: {
    target: "es2022",
    sourcemap: true,
    lib: {
      entry: {
        index: fileURLToPath(new URL("src/index.ts", import.meta.url)),
        auto: fileURLToPath(new URL("src/auto.ts", import.meta.url)),
      },
      formats: ["es"],
    },
  },
  test: {
    include: ["test/**/*.test.ts"],
    environment: "happy-dom",
    restoreMocks: true,
  },
});
