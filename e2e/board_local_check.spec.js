const { test, expect } = require("@playwright/test");

// The BUILDING card's local-check indicator (feature: show-local-test-progress) —
// the CI meter's counterpart for the stretch before a PR exists.
//
// Why this needs a real browser rather than only the rendered-partial tier: the two
// states differ by an ANIMATION and a LIVE CLOCK, and both are invisible to
// assert_select. A spinner that does not actually spin, or a "running" clock frozen
// at its server-rendered value, would pass every request test while telling the
// operator nothing — the indicator would look alive on a card that is not.
//
// THE SPEC OWNS ITS OWN FIXTURES, and does not add them to e2e/seed.rb. That is the
// same discipline e2e/ci_meter_fit.spec.js keeps, and it is not stylistic: these
// cards were briefly seeded instead, and e2e/overflow_fade.spec.js went red twice on
// CI. That spec loads /tasks and measures the card title with the highest
// scrollWidth/clientWidth ratio on the board — a selection that is only as stable as
// the board's contents, so ANY permanently-seeded card is a change to another spec's
// input. Minting here and deleting in the same test keeps the shared board exactly
// as every other spec found it.
//
// Clock states are driven by Playwright's CLOCK rather than by waiting on real time,
// because the shared ticker renders data-mode="short" as a SINGLE unit ("47s", then
// "3m") — past a minute the text only changes once per minute, so any real-time poll
// short enough to keep the suite fast could never observe a change, and a longer one
// would just be a slow way to be flaky.

test.use({ viewport: { width: 1600, height: 1000 } });

// The board carries a signed API token for exactly this purpose (meta e2e-api-token).
const api = (page, method, path, body) =>
  page.evaluate(
    async ([m, p, b]) => {
      const token = document.querySelector('meta[name="e2e-api-token"]')?.content;
      const res = await fetch(p, {
        method: m,
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: b ? JSON.stringify(b) : undefined,
      });
      return { status: res.status, body: await res.text() };
    },
    [method, path, body]
  );

// A building task plus an in-flight g1_cert attempt carrying one `running` lane —
// exactly what bin/fast-check leaves behind while a cert is mid-flight.
async function mintCheck(page, { slug, title, lane, cmd, beatAt }) {
  // Params are permitted FLAT on this endpoint (Api::V1::TasksController#task_params),
  // not nested under a `task:` key, and `devops` is its own top-level key that the
  // controller normalizes into metadata.
  const created = await api(page, "POST", "/api/v1/tasks", {
    title,
    slug,
    stage: "building",
    devops: { repositories: ["mcritchie-studio"] },
  });
  expect([200, 201], `create ${slug}: ${created.body.slice(0, 200)}`).toContain(created.status);

  // /api/v1/gates/:subject_type/:subject_slug/:key/... — gate runs are their own
  // subject-addressed resource, NOT nested under the task.
  const opened = await api(page, "POST", `/api/v1/gates/task/${slug}/g1_cert/open`, {});
  expect([200, 201], `open gate: ${opened.body.slice(0, 200)}`).toContain(opened.status);

  const sop = await api(page, "POST", `/api/v1/gates/task/${slug}/g1_cert/sops`, {
    sop: { sop: lane, cmd, result: "running", at: beatAt },
  });
  expect([200, 201], `append sop: ${sop.body.slice(0, 200)}`).toContain(sop.status);
}

const iso = (msAgo) => new Date(Date.now() - msAgo).toISOString();

test("a building card names the lane its local cert is running, with a live clock", async ({ page }) => {
  const slug = "e2e-local-check-running";
  await page.goto("/tasks");
  await mintCheck(page, {
    slug,
    title: "E2E local check running",
    lane: "mapped-tests",
    cmd: "bin/rails test test/models/widget_test.rb",
    beatAt: iso(5_000), // a fresh beat — well inside the staleness window
  });

  try {
    await page.goto("/tasks");
    const card = page.locator(`#card-${slug}`);
    await expect(card).toBeVisible();

    const slot = card.locator("[data-test='task-local-check']");
    await expect(slot).toHaveAttribute("data-local-check-state", "running");
    await expect(slot.locator("[data-test='task-local-check-label']")).toHaveText(/Running mapped tests/);

    // The spinner is genuinely animating — the thing that says "still working".
    const spinner = slot.locator("[data-test='task-local-check-spinner']");
    await expect(spinner).toBeVisible();
    await expect(spinner).toHaveClass(/animate-spin/);

    // The command rides along so the operator can see what is executing.
    await expect(slot).toHaveAttribute("title", /bin\/rails test/);

    // THE CLOCK MUST ACTUALLY TICK. A server-rendered number that never moves is the
    // exact failure this indicator is supposed to rule out.
    const clock = slot.locator("[data-test='task-local-check-clock']");
    await expect(clock).toHaveAttribute("data-local-check-clock", "running");
    await expect(clock).toHaveAttribute("data-release-ticker", "");
    const first = await clock.textContent();
    await page.clock.install();
    await page.clock.fastForward("02:00");
    await expect.poll(async () => await clock.textContent(), { timeout: 5000 }).not.toBe(first);
  } finally {
    await api(page, "DELETE", `/api/v1/tasks/${slug}`);
  }
});

test("a killed runner shows STALLED with a frozen clock, never an endless spinner", async ({ page }) => {
  const slug = "e2e-local-check-stalled";
  await page.goto("/tasks");
  await mintCheck(page, {
    slug,
    title: "E2E local check stalled",
    lane: "full-suite",
    cmd: "bin/rails db:test:prepare test test:system",
    beatAt: iso(25 * 60_000), // last beat 25 minutes ago — the runner is gone
  });

  try {
    await page.goto("/tasks");
    const card = page.locator(`#card-${slug}`);
    await expect(card).toBeVisible();

    const slot = card.locator("[data-test='task-local-check']");
    await expect(slot).toHaveAttribute("data-local-check-state", "stalled");
    await expect(slot.locator("[data-test='task-local-check-label']")).toHaveText(/stalled/i);

    // No spinner: a stalled check must stop claiming progress.
    await expect(slot.locator("[data-test='task-local-check-spinner']")).toHaveCount(0);
    await expect(slot.locator("[data-test='task-local-check-stalled-icon']")).toBeVisible();

    // And the clock is FROZEN — it must not keep counting up on a dead process. Same
    // fast-forward as the running case, so this is a real control rather than a pause
    // too short for the minute-granularity to have moved anyway.
    const clock = slot.locator("[data-test='task-local-check-clock']");
    await expect(clock).toHaveAttribute("data-local-check-clock", "stalled");
    await expect(clock).not.toHaveAttribute("data-release-ticker", /.*/);
    const first = await clock.textContent();
    await page.clock.install();
    await page.clock.fastForward("02:00");
    await page.waitForTimeout(500);
    await expect(clock).toHaveText(first);
  } finally {
    await api(page, "DELETE", `/api/v1/tasks/${slug}`);
  }
});
