const { test, expect } = require("@playwright/test");

// [e2e] THE OPERATOR-WINDOW COUNTDOWN RENDERS AND TICKS. A card whose task waits on
// the operator (a `waiting` UI approval, or an `Escalated:` dependency block) wears
// a countdown chip beside its slug row (tasks/_window_chip); the install-once
// ticker advances it every second and flips a lapsed window to the kind's lapsed
// label; a card with nothing waiting wears no chip.
//
// THE SPEC OWNS ITS OWN FIXTURES, and does not add them to e2e/seed.rb — the
// discipline e2e/board_local_check.spec.js and e2e/ci_meter_fit.spec.js keep, and
// measured again here: three seeded window cards turned e2e/overflow_fade.spec.js
// red (it picks the board's card title closest to its edge, so any permanent card
// is a change to its input; the two waiting cards also float to the top of the
// column). Minted through the board's own API before each read and deleted in a
// `finally`, so the shared board is exactly as every other spec found it.
//
// The live approval is posted at mint time, so its chip reads "mm:ss" and TICKS;
// the hour-old one reads the lapsed label deterministically, so "lapsed" is never
// proven only by a slow run. Clock text is real time, deliberately: the window
// tick is the thing under test.
const CLOCK = /^\d{2}:\d{2}$/;

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
    [method, path, body],
  );

async function mintTask(page, slug, attrs) {
  const res = await api(page, "POST", "/api/v1/tasks", { slug, priority: 1, agent_slug: "mack", ...attrs });
  expect(res.status, `mint ${slug}: ${res.body}`).toBe(201);
  return slug;
}

async function deleteTasks(page, slugs) {
  for (const slug of slugs) {
    const res = await api(page, "DELETE", `/api/v1/tasks/${slug}`);
    expect([204, 404], `delete ${slug}: ${res.body}`).toContain(res.status);
  }
}

test("a waiting approval's card wears a ticking countdown, a lapsed one reads the lapsed label", async ({ page }) => {
  const suffix = Date.now();
  const liveSlug = `e2e-window-live-${suffix}`;
  const lapsedSlug = `e2e-window-lapsed-${suffix}`;
  expect((await page.goto("/tasks")).ok()).toBe(true);
  const minted = [];
  try {
    const devops = { kind: "feature", repositories: ["mcritchie-studio"], approval_status: "waiting" };
    // A request posted NOW: Task#stamp_operator_approval_request fills approval_requested_at.
    // Params are permitted FLAT on this endpoint and `devops` is its own top-level
    // key the controller normalizes into metadata (the board_local_check idiom).
    minted.push(await mintTask(page, liveSlug, { title: "Window live approval demo", stage: "building", devops }));
    // A request an hour old: the stamp KEEPS a caller-supplied approval_requested_at.
    const hourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    minted.push(await mintTask(page, lapsedSlug, { title: "Window lapsed approval demo", stage: "building",
      devops: { ...devops, approval_requested_at: hourAgo } }));

    await page.reload();

    const live = page.locator(`#card-${liveSlug} [data-test='task-window-chip']`);
    await expect(live).toBeVisible();
    await expect(live).toHaveAttribute("data-window-kind", "approval");
    await expect(live).toHaveAttribute("data-window-state", "open");
    const liveClock = live.locator("[data-test='task-window-clock']");
    await expect(liveClock).toHaveAttribute("data-mode", "window");
    const first = (await liveClock.textContent()).trim();
    expect(first).toMatch(CLOCK);
    // The ticker advances the painted value: within ~2s the text must differ and
    // still read as a clock.
    await expect.poll(async () => (await liveClock.textContent()).trim(), { timeout: 5_000 }).not.toBe(first);
    expect((await liveClock.textContent()).trim()).toMatch(CLOCK);
    // The WAITING APPROVAL bar still rides the card beneath the clock.
    await expect(page.locator(`#card-${liveSlug} [data-test='operator-approval-waiting']`)).toHaveCount(1);

    // The hour-old request: lapsed for certain, dimmed, and its label names the default.
    const lapsed = page.locator(`#card-${lapsedSlug} [data-test='task-window-chip']`);
    await expect(lapsed).toBeVisible();
    await expect(lapsed).toHaveAttribute("data-window-kind", "approval");
    await expect(lapsed).toHaveAttribute("data-window-state", "lapsed");
    await expect(lapsed.locator("[data-test='task-window-clock']")).toHaveText("unanswered, proceeding");
    await expect(lapsed).not.toHaveAttribute("data-window-urgent", "true");

    // A card with nothing waiting on the operator wears no chip at all.
    const bystander = page.locator("#card-e2e-epic-chip-demo");
    await expect(bystander).toBeVisible();
    await expect(bystander.locator("[data-test='task-window-chip']")).toHaveCount(0);
  } finally {
    await deleteTasks(page, minted);
  }
});

test("an Escalated dependency block wears the escalation countdown", async ({ page }) => {
  const slug = `e2e-window-escalation-${Date.now()}`;
  expect((await page.goto("/tasks")).ok()).toBe(true);
  const minted = [];
  try {
    minted.push(await mintTask(page, slug, { title: "Window escalation block demo", stage: "submitted",
      devops: { kind: "feature", repositories: ["mcritchie-studio"] } }));
    // Avi's arbitrate-block step 8, over the wire: a dependency block whose summary
    // leads `Escalated:` — the block columns from the block endpoint, the two-part
    // record from the activities API.
    const blocked = await api(page, "PATCH", `/api/v1/tasks/${slug}/block`,
      { by: "avi", kind: "dependency", event: { source: "cli", actor: "avi" } });
    expect(blocked.status, blocked.body).toBe(200);
    const noted = await api(page, "POST", "/api/v1/activities", {
      task_slug: slug, activity_type: "qa_feedback", agent_slug: "avi",
      description: "POLICY QUESTION for Alex. Reviewer: keep the chip amber. Builder: match the bar. " +
        "Avi's recommendation: amber. Window: 20 min; on lapse the recommendation stands.",
      metadata: { summary: "Escalated: chip colour default", kind: "dependency" },
    });
    expect([200, 201], noted.body).toContain(noted.status);

    await page.reload();

    const card = page.locator(`#card-${slug}`);
    await expect(card).toBeVisible();
    const chip = card.locator("[data-test='task-window-chip']");
    await expect(chip).toHaveCount(1);
    await expect(chip).toHaveAttribute("data-window-kind", "escalation");
    await expect(chip).toHaveAttribute("data-window-state", "open");
    // Seconds into a twenty-minute window: "20:00" or the 19:xx band (the block
    // landed under a second before this paint), and ticking.
    const clock = chip.locator("[data-test='task-window-clock']");
    const first = (await clock.textContent()).trim();
    expect(first).toMatch(/^(20:00|19:\d{2})$/);
    await expect.poll(async () => (await clock.textContent()).trim(), { timeout: 5_000 }).not.toBe(first);
    // The blocker's own summary still rides the card beneath it.
    await expect(card.locator("[data-test='blocker-summary']")).toHaveText("Escalated: chip colour default");
  } finally {
    await deleteTasks(page, minted);
  }
});
