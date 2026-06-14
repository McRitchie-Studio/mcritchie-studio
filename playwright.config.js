const { defineConfig } = require("@playwright/test");
const port = process.env.E2E_PORT || "3000";

module.exports = defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  workers: 1,
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    headless: true,
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
  ],
  webServer: {
    command:
      `bin/rails db:test:prepare && bin/rails runner e2e/seed.rb && bin/rails server -p ${port} -e test`,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
    env: { RAILS_ENV: "test", LOCAL_EMAIL_CAPTURE: "1" },
  },
});
