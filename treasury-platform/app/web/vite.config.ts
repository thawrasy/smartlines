import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The portal is served by the API host in production (ADR 0040); in development Vite proxies /api to it.
export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': 'http://localhost:5080' } },
  // No source maps in the build (docs/31 row 48): the browser's tools show only the minified bundle, not the source.
  build: { outDir: 'dist', sourcemap: false },
  test: { environment: 'jsdom' },
});
