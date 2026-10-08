// End-to-end tests: the web build in Chromium, with the server's API
// answered by mock_api.js. Build first, with relative API calls:
//
//   flutter build web --no-web-resources-cdn --dart-define=API_BASE=
//   cd e2e && npm install && npx playwright test
const { defineConfig } = require('@playwright/test');

const port = Number(process.env.PORT || 4300);

module.exports = defineConfig({
  testDir: './tests',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  // one editor at a time: each test boots the whole app, and in parallel the
  // first frames of a cold CanvasKit fight over the CPU
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${port}`,
    viewport: { width: 1280, height: 900 },
    locale: 'en-US',
    trace: 'retain-on-failure',
    launchOptions: process.env.CHROMIUM_PATH
      ? { executablePath: process.env.CHROMIUM_PATH }
      : {},
  },
  webServer: {
    command: 'node serve.js',
    port,
    reuseExistingServer: true,
  },
});
