// The printed pages' fonts at stable names (ADR 0055): copied from the bundled @fontsource packages into public/fonts,
// so the site serves them at /fonts for the browser, and the API image installs the same files for Chromium's PDF.
import { copyFileSync, mkdirSync } from 'node:fs';

const src = (pkg, subset, weight) => `node_modules/@fontsource/${pkg}/files/${pkg}-${subset}-${weight}-normal.woff2`;
const files = {
  'plex-sans-arabic-400.woff2': src('ibm-plex-sans-arabic', 'arabic', 400),
  'plex-sans-arabic-600.woff2': src('ibm-plex-sans-arabic', 'arabic', 600),
  'plex-sans-arabic-700.woff2': src('ibm-plex-sans-arabic', 'arabic', 700),
  'plex-sans-400.woff2': src('ibm-plex-sans', 'latin', 400),
  'plex-sans-600.woff2': src('ibm-plex-sans', 'latin', 600),
  'plex-sans-700.woff2': src('ibm-plex-sans', 'latin', 700),
  'plex-mono-400.woff2': src('ibm-plex-mono', 'latin', 400),
};
mkdirSync('public/fonts', { recursive: true });
for (const [name, from] of Object.entries(files)) copyFileSync(from, `public/fonts/${name}`);
