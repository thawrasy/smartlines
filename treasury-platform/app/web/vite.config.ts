import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The portal is served by the API host in production (ADR 0040); in development Vite proxies /api to it.
export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': 'http://localhost:5080' } },
  build: { outDir: 'dist', sourcemap: true },
  test: { environment: 'jsdom' },
});
