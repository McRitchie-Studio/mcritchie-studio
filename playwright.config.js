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
//
// And that last paragraph is a NORM, which is exactly what this lane's own thesis says is
// never enough — so it is backed by a GATE. test/lib/e2e_quarantine_ratchet_test.rb pins
// the EXECUTED SET: 69 specs − 18 quarantined == the 51 this lane runs. Not the ci.yml
// command — the SET. So every way of dropping a spec out of the lane is red, not just the
// one we thought of: `@quarantine`, `test.only`, `test.skip`, `test.fixme`, a `testDir` or
// `testIgnore` edit, a deleted spec file, an empty shard. Repair a spec and it makes you
// lower the ceiling in the same commit, so the hole cannot quietly grow back.
//
// That matters because the FIRST version of this guard bound the ci.yml COMMAND and not the
// set, and review defeated it in one word: `.only` on a healthy spec, lane collapses 51 → 1,
// three shards green, every guard green. Bounded, not merely deplored — and bounded by the
// property, not by a list of the spellings we happened to imagine.
const { defineConfig } = require("@playwright/test");
const port = process.env.E2E_PORT || "3000";
const externalBaseURL = process.env.QA_BASE_URL || process.env.PW_BASE_URL || process.env.BASE_URL;
const baseURL = externalBaseURL || `http://127.0.0.1:${port}`;

const config = {
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  workers: 1,
  // A COMMITTED `test.only` COLLAPSES THIS LANE TO ONE SPEC, ENTIRELY GREEN — and without
  // this line nothing anywhere notices. Found by mutation in review of #543: `.only` on one
  // healthy spec takes the lane from 51 specs to 1. Shard 1/3 runs that single test and
  // passes; shards 2/3 and 3/3 select ZERO tests and — this is the part that bites —
  // **exit 0**. Unsharded, playwright's own zero-test guard fires ("No tests found", exit 1)
  // and the mistake fails safe; SHARDED, an empty shard is silent. So the very thing that
  // makes this lane fast is the thing that disarms its last line of defense.
  //
  // `forbidOnly` turns a committed `.only` into exit 1 on all three shards under CI, while
  // leaving `.only` usable as the local debugging tool it is meant to be. It is the cheap
  // hard stop for the worst spelling. It is NOT the durable fix: it bounds ONE spelling, and
  // `.skip`/`.fixme` walk straight past it. What bounds the rest is the EXECUTED SET being
  // pinned statically — test/lib/e2e_quarantine_ratchet_test.rb asserts 69 specs − 18
  // quarantined == the 51 this lane runs, so `.only`, `.skip`, `.fixme`, a `testDir`/
  // `testIgnore` edit, a deleted spec file and an empty shard all turn the Rails test job
  // red. Belt (here, at the lane) and braces (there, at the set).
  forbidOnly: !!process.env.CI,
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
    // tailwindcss:build is LOAD-BEARING, and its absence is invisible until every page
    // 500s. app/assets/builds/ is GITIGNORED — a fresh checkout (a new worktree, or any
    // CI runner) has nothing in it but .keep — and `db:test:prepare` does NOT build it.
    // Only `test:prepare`, the hook tailwindcss-rails enhances, does; the argless
    // `bin/rails test` gets that for free, which is exactly why this suite's own boot
    // path never did. Without this, the server boots FINE and then every single request
    // dies in the view layer with `The asset "tailwind.css" is not present in the asset
    // pipeline`, and all 69 specs fail on assertions that have nothing to do with CSS.
    // Cost is ~0.4s. This is the first thing that bit the CI lane on the day it was
    // wired (PR #543): green on a laptop that had run test:prepare by hand, red on
    // every clean runner.
    command:
      `bin/rails db:test:prepare && bin/rails tailwindcss:build && bin/rails runner e2e/seed.rb && bin/rails server -p ${port} -e test`,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !process.env.CI,
    // The command above chains FOUR Rails boots (db:test:prepare, tailwindcss:build,
    // the seed runner, then the server) before /up can answer. At ~4-8s per boot a
    // loaded machine blows a 30s ceiling with the server perfectly healthy — measured
    // 3/5 boot flakes under load (task stabilize-deployments-e2e-spec). 120s is
    // pure headroom: a fast boot still starts in ~15s, only the timeout moved.
    timeout: 120_000,
    // CABLE_ADAPTER=async gives the e2e server REAL in-process ActionCable delivery
    // to the browser (the default `test` adapter only captures broadcasts for
    // minitest assertions), so the /deployments live-update round-trip works.
    env: {
      RAILS_ENV: "test",
      LOCAL_EMAIL_CAPTURE: "1",
      CABLE_ADAPTER: "async",
      // The Last Release fresh-deploy glow window (ApplicationHelper#
      // fresh_deploy_window_ms; production default 8s). 8s turned
      // release_ship.spec.js into a wall-clock race: the spec's own arrival
      // waits + reload could eat the whole window under machine load, and its
      // fresh-deploy assertions then met a glow that had ALREADY expired — a
      // state no timeout can wait back into (reproduced on the base seed under
      // 8-way load, task stabilize-release-ship-spec). 20s keeps the glow
      // mechanics identical while giving the fresh-phase assertions ~2x
      // headroom; the spec reads the live value back from data-fresh-window-ms
      // and budgets its expiry wait from it, so this number is spelled ONCE.
      FRESH_DEPLOY_WINDOW_MS: "20000",
      // Deterministic CI check counts for the board's CI progress bars (feature:
      // visual-ci-progress-bars), keyed by the SHAs e2e/seed.rb assigns to the demo
      // task branch + the release-branch CI run — so the reader folds real numbers
      // without a GitHub round-trip.
      CI_PROGRESS_FIXTURES: JSON.stringify({
        "e2e-task-sha": { passed: 6, failed: 0, pending: 2 },
        "e2e-rel-sha": { passed: 8, failed: 0, pending: 0 },
      }),
    },
  };
}

module.exports = defineConfig(config);
