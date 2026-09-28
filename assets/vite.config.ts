import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: process.env.ATOLL_ASSETS_OUT ?? "../priv/static/assets",
    emptyOutDir: false,
    manifest: false,
    sourcemap: false,
    rollupOptions: {
      input: "src/main.tsx",
      output: {
        entryFileNames: "account.js",
        chunkFileNames: "account-[name].js",
        assetFileNames: (asset) =>
          asset.names?.[0]?.endsWith(".css") ? "account.css" : "account-[name][extname]",
      },
    },
  },
  test: {
    globals: true,
    environment: "happy-dom",
    setupFiles: ["src/test/setup.ts"],
    css: false,
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
