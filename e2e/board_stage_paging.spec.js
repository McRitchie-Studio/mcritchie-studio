const { test, expect } = require("@playwright/test");

// THE ARCHIVE, A PAGE AT A TIME — AND A BADGE THAT STAYS TRUE WHILE THE PAGE LIVES.
//
// An explicit ?stage= view draws one Task::BOARD_STAGE_LIMIT (100) page of its stage.
// The hotfix for archived-board-crashes-prod capped it in SQL after a crawler's
// uncapped ?stage=archived took production down; archive-board-cap-followups added the
// paging and made both boards' badges report the TRUE total.
//
// The server half — what a page loads, draws and counts — is pinned by the Rails
// controller tests. What only a browser can show is the badge AFTER the page has been
// alive for a moment: both boards recount their dropzones on every live Turbo update,
// and a recount only sees the drawn cards. Before this spec's change, the first
// broadcast to touch the column rewrote the true total to the drawn size. Removing a
// drawn card here is exactly what a Turbo `remove` stream does, so the recount must
// land on total − 1, never on 99.

const LIMIT = 100;

async function createTask(page, token, attrs) {
  const res = await page.request.post("/api/v1/tasks", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: attrs,
  });
  expect(res.ok(), await res.text()).toBeTruthy();
}

async function archivedBadgeTotal(page, selector) {
  return Number((await page.locator(selector).first().textContent()).trim());
}

test("archived stage pages stay bounded and both boards keep the true total", async ({ page }) => {
  test.setTimeout(120_000);

  await page.goto("/tasks?stage=archived");
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");

  // The column must hold more than one page. Seed only the shortfall, so a re-run on a
  // local test database does not grow it without bound.
  const existing = await archivedBadgeTotal(page, "[data-board-count='archived']");
  const suffix = Date.now();
  const missing = Math.max(0, LIMIT + 5 - existing);
  for (let i = 0; i < missing; i += 5) {
    await Promise.all(
      Array.from({ length: Math.min(5, missing - i) }, (_, j) =>
        createTask(page, token, {
          slug: `e2e-stage-paging-${suffix}-${i + j}`,
          title: `E2E stage paging archived ${i + j}`,
          stage: "archived",
        })
      )
    );
  }

  // --- /tasks (the engine board primitive) ------------------------------------
  await page.goto("/tasks?stage=archived");
  await expect(page.locator("[data-test='kanban-board'][data-alpine-ready='true']")).toHaveCount(1);
  const tasksBadge = page.locator("[data-board-count='archived']");
  const total = await archivedBadgeTotal(page, "[data-board-count='archived']");
  expect(total).toBeGreaterThan(LIMIT);
  await expect(page.locator("#dropzone-archived .kanban-card")).toHaveCount(LIMIT);

  // A live removal recounts the column. The badge MOVES (total → total − 1), which
  // only the recount can do, so this cannot pass on a recount that never ran.
  await page.evaluate(() => document.querySelector("#dropzone-archived .kanban-card").remove());
  await expect(tasksBadge).toHaveText(String(total - 1));

  // Older → is page 2: still bounded, still the true total, and a way back.
  await page.locator("[data-test='stage-pager'][data-pager-position='top'] [data-test='stage-pager-older']").click();
  await expect(page).toHaveURL(/[?&]page=2\b/);
  await expect(tasksBadge).toHaveText(String(total));
  const pageTwoCards = await page.locator("#dropzone-archived .kanban-card").count();
  expect(pageTwoCards).toBeGreaterThan(0);
  expect(pageTwoCards).toBeLessThanOrEqual(LIMIT);
  await expect(page.locator("[data-test='stage-pager-newer']").first()).toBeVisible();
  // A filtered page never offers the default board's "N older" link to itself.
  await expect(page.locator("a[data-test='stage-older-link']")).toHaveCount(0);

  // --- /deployments (the hand-rolled deploy board) -----------------------------
  await page.goto("/deployments?stage=archived");
  await expect(page.locator("[data-test='kanban-board'][data-alpine-ready='true']")).toHaveCount(1);
  const deployBadge = page.locator("[data-stage-count='archived']");
  await expect(deployBadge).toHaveText(String(total));
  await expect(page.locator("#dropzone-archived .kanban-card")).toHaveCount(LIMIT);

  await page.evaluate(() => document.querySelector("#dropzone-archived .kanban-card").remove());
  await expect(deployBadge).toHaveText(String(total - 1));
});
