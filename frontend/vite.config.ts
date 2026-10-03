import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The API runs on 8077 in development; in production the same FastAPI process serves dist/.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { "/api": "http://localhost:8077" } },
  // No inlined assets: the CSP does not allow data: fonts
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 900, assetsInlineLimit: 0 },
});
