// The `e2e` tier's suite. CI runs it as the sharded `playwright` job in
// .github/workflows/ci.yml — as of 2026-07-13. Before that NO lane ran it at all, while
// config/feature_shapes.yml demanded the `e2e` tier of every `ui+db` change: the
// requirement was met by a builder typing "[e2e] ..." into checks_run and bin/dor-check
// crediting the tag. A gate that demands evidence it never collects.
//
// THE @quarantine TAG. When the lane was switched on, 18 of these 69 specs were already
// RED on an untouched `release` checkout — the suite had gone unrun long enough for a
// quarter of it to rot (the board grew agent/app filters that hide the cards the live
// specs wait on; a seeded fixture string vanished). Those 18 carry ` @quarantine` in
// their title and CI excludes them with `--grep-invert @quarantine`, so the healthy 51
// get a real lane TODAY instead of waiting on the repair — and a rotted suite does not
// paint CI red for every PR in flight.
//
// It is a hole, and it is named: those 18 specs are covered by NOTHING right now. Do not
// read the green `playwright` check as "the e2e suite passes". Repair is ticketed at
// /tasks/repair-rotted-e2e-specs; when it lands, drop the tags AND the --grep-invert
// flag. Never tag a spec @quarantine to get a PR green — that is the disease this whole
// lane exists to cure. Fix it, or block on it.
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
    // CABLE_ADAPTER=async gives the e2e server REAL in-process ActionCable delivery
    // to the browser (the default `test` adapter only captures broadcasts for
    // minitest assertions), so the /deployments live-update round-trip works.
    env: { RAILS_ENV: "test", LOCAL_EMAIL_CAPTURE: "1", CABLE_ADAPTER: "async" },
  };
}

module.exports = defineConfig(config);
