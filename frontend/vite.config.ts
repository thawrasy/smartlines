import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The API runs on 8077 in development; in production the same FastAPI process serves dist/.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { "/api": "http://localhost:8077" } },
  // No inlined assets: the CSP does not allow data: fonts. No source maps ship with the bundle, so the
  // browser exposes only minified code — no original file names, module layout or comments a developer left
  // behind (owner's request, October 2026: protect the browser source from misuse). The edge refuses any
  // request for a *.js.map path as well (deploy/Caddyfile, and the shield's "probe" rule in migration 1142).
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 900, assetsInlineLimit: 0 },
});
