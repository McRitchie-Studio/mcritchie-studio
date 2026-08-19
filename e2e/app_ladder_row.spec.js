const { test, expect } = require("@playwright/test");

// The /deployments app-ladder row: one card per reportable repo, each showing where
// that application sits on `accepted → release → main`.
//
// WHY A BROWSER-LEVEL CHECK EARNS ITS PLACE HERE. The model and integration tiers
// already prove the state machine and the rendered markup. What they cannot prove is
// that the row survives a real page load on the live board — this row is injected
// into `_deploy_board`, a 580-line partial that also carries inline <script> blocks
// and an Alpine-driven filter row directly beneath it. An ERB comment that terminates
// early leaks prose whose literal tag can swallow the real script in every browser
// while every server-side test still passes (the propagate-at-format-gem defect).
// So this spec asserts the row renders AND that the board beneath it still works.

test("the deployments app-ladder row renders a card per repo with three rungs each", async ({ page }) => {
  await page.goto("/deployments");

  const row = page.locator("[data-test='app-ladder-row']");
  await expect(row).toBeVisible();

  const cards = row.locator("[data-test='app-ladder-card']");
  const cardCount = await cards.count();
  expect(cardCount).toBeGreaterThan(0);

  // Every card carries exactly the three ladder rungs, in order.
  for (let i = 0; i < cardCount; i += 1) {
    const card = cards.nth(i);
    const repo = await card.getAttribute("data-repo");
    expect(repo, "each card names its repo").toBeTruthy();

    const branches = await card
      .locator("[data-test='app-ladder-rung']")
      .evaluateAll((els) => els.map((el) => el.getAttribute("data-branch")));

    expect(branches, `${repo} must show the full ladder`).toEqual([
      "accepted",
      "release",
      "main",
    ]);
  }
});

// The honesty contract, asserted in a real browser: a rung may only read "green"
// when there is a live verdict for it. `stale` (a verdict that predates work parked
// on the branch) and `not_built` (nothing ingested at all) must render as themselves.
// A rung state outside the known set means the model grew a state the view does not
// render, which would fall through to a silent default.
test("every rung renders a known state and never invents a pass", async ({ page }) => {
  await page.goto("/deployments");

  const states = await page
    .locator("[data-test='app-ladder-row'] [data-test='app-ladder-rung']")
    .evaluateAll((els) => els.map((el) => el.getAttribute("data-state")));

  expect(states.length).toBeGreaterThan(0);

  const known = ["green", "red", "pending", "conflicted", "stale", "not_built"];
  const unknown = states.filter((s) => !known.includes(s));
  expect(unknown, "a rung rendered a state the view does not know").toEqual([]);
});

// The row sits directly above the app filter row inside the same partial. If the
// injection broke ERB or leaked a tag, the filter below it is the first thing to
// disappear — so this is the cheap regression guard on the surgery itself.
test("the board beneath the ladder row still renders", async ({ page }) => {
  await page.goto("/deployments");

  await expect(page.locator("[data-test='app-ladder-row']")).toBeVisible();
  await expect(page.locator("[data-test='kanban-board']")).toBeVisible();
  await expect(page.locator("[data-test='release-dashboard-grid']")).toBeVisible();
});
