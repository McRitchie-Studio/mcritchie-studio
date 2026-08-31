const { test, expect } = require("@playwright/test");

// The /deployments DESK PANEL — the worktree desks and their teardown records.
//
// WHY IT EXISTS AT ALL. The desk ledger used to be docs/agents/maintenance/delete-later.md,
// and `bin/agent-worktree` wrote its teardown rows into whatever checkout it ran from.
// Cleanups run from the PRIMARY, which sits on `main` — a branch nobody may commit to — so
// the audit row was created in the one place it could never be saved from. 98 rows were
// stranded in six "restore later" stashes; none was ever restored.
//
// WHY A BROWSER-LEVEL CHECK EARNS ITS PLACE. The model tier proves the episode semantics and
// the component tier proves the markup, and neither can prove the panel survives a real load
// of /deployments — a page that also carries a 380-line inline Alpine factory, a 700-line
// board partial and a Turbo-Stream subscription. An ERB comment that terminates early leaks
// prose whose literal tag can swallow the script that follows in every browser while every
// server-side test still passes. So this asserts the panel renders on the live page, that
// the board above it still works, and that the panel does not push the page sideways.

test("the desk panel renders on /deployments with the numbers an operator judges by", async ({ page }) => {
  await page.goto("/deployments");

  const panel = page.locator("[data-test='desk-panel']");
  await expect(panel).toBeVisible();

  // The four tiles, each carrying a real number rather than a dash.
  for (const tile of ["desks", "band", "dirty", "held"]) {
    const value = panel.locator(`[data-test='desk-tile-${tile}'] .font-mono`).first();
    await expect(value).toBeVisible();
    await expect(value).not.toHaveText("—");
  }

  // The free-slot count is meaningless without the band it is out of.
  await expect(panel.locator("[data-test='desk-tile-band']")).toContainText("of 55");

  // Every live desk carries WHY it is free or WHY it is held — never a blank cell where a
  // decision should be.
  const accounts = await panel
    .locator("[data-test='desk-safety']")
    .evaluateAll((els) => els.map((el) => el.textContent.trim()));
  expect(accounts.length).toBeGreaterThan(0);
  expect(accounts.every((text) => text.length > 0)).toBe(true);
  expect(accounts.some((text) => text.includes("live-claiming"))).toBe(true);
  expect(accounts.some((text) => text.includes("merged into origin/accepted"))).toBe(true);

  // A finished desk says the date it went and the reason it was safe to take — the cell the
  // markdown ledger existed to carry.
  const finished = panel.locator("[data-test='desk-removed-row']").first();
  await expect(finished).toContainText("removed 2026-08-18");
  await expect(
    panel.locator("[data-test='desk-removed-reason']").first(),
  ).toContainText("contained in origin/accepted");
});

test("a desk that left without a teardown record is called out on the live page", async ({ page }) => {
  await page.goto("/deployments");

  const strip = page.locator("[data-test='desk-panel-vanished']");
  await expect(strip).toBeVisible();
  await expect(strip).toContainText("left without a teardown record");
  await expect(strip).toContainText("e2e-desk-vanished");
});

test("the desk panel sits below the board and never widens the page", async ({ page }) => {
  await page.goto("/deployments");

  const panel = page.locator("[data-test='desk-panel']");
  const board = page.locator("[data-test='kanban-board']");
  await expect(panel).toBeVisible();
  await expect(board).toBeVisible();

  // The board is the work; the desks are the machine it runs on. An operator scanning this
  // page reaches the pipeline first.
  const [panelTop, boardTop] = await Promise.all([
    panel.evaluate((el) => el.getBoundingClientRect().top + window.scrollY),
    board.evaluate((el) => el.getBoundingClientRect().top + window.scrollY),
  ]);
  expect(panelTop).toBeGreaterThan(boardTop);

  // A COMPUTED fact no server-side test can produce: the panel's own content — long branch
  // names, long rationale sentences, a four-tile grid — must not make the document scroll
  // sideways. Measured on the document, because a panel that overflows takes the whole
  // board with it.
  const overflow = await page.evaluate(() => {
    const doc = document.documentElement;
    return doc.scrollWidth - doc.clientWidth;
  });
  expect(overflow).toBeLessThanOrEqual(1);
});
