const { defineConfig } = require("@playwright/test");
const port = process.env.E2E_PORT || "3000";
const externalBaseURL = process.env.QA_BASE_URL || process.env.PW_BASE_URL || process.env.BASE_URL;
const baseURL = externalBaseURL || `http://127.0.0.1:${port}`;

const config = {
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  workers: 1,
  use: {
    baseURL,
    headless: true,
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
  ],
};

if (!externalBaseURL) {
  config.webServer = {
    command:
      `bin/rails db:test:prepare && bin/rails runner e2e/seed.rb && bin/rails server -p ${port} -e test`,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
    env: { RAILS_ENV: "test", LOCAL_EMAIL_CAPTURE: "1" },
  };
}

module.exports = defineConfig(config);
