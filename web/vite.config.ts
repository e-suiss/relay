import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";
import { contentSecurityPolicy } from "./src/app/csp";

export default defineConfig({
  base: "/console/",
  plugins: [react()],
  build: {
    outDir: "dist",
    assetsDir: "assets",
    sourcemap: false,
    modulePreload: { polyfill: false },
  },
  preview: {
    port: 4173,
    strictPort: true,
    headers: { "content-security-policy": contentSecurityPolicy },
  },
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.{ts,tsx}"],
    setupFiles: ["src/test-setup.ts"],
    restoreMocks: true,
  },
});
