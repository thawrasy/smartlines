// Browser tests of S0 (ADR 0040): tools/ci/e2e.sh starts the API and the worker on HTTPS (a throwaway certificate)
// and points every *.bankfas.test name at them; the tests then walk the S0 exit path in Chromium.
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 300_000,
  workers: 1,
  reporter: [['list']],
  use: {
    ignoreHTTPSErrors: true,
    actionTimeout: 20_000,
    launchOptions: {
      executablePath: process.env.E2E_CHROMIUM || undefined,
      args: [`--host-resolver-rules=MAP *.bankfas.test 127.0.0.1, MAP bankfas.test 127.0.0.1`, '--no-proxy-server'],
    },
    trace: 'retain-on-failure',
  },
});
