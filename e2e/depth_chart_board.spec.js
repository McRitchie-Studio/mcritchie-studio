const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// The NFL depth chart, rebased onto the studio/board engine primitive (studio-engine
// 0.29.0). These specs assert the effect: the board renders through the primitive with
// the card/dropzone identity contract in a two-level side→position GRID (DG3), a pinned
// starter carries .kanban-locked (DG4), and a within-lane reorder persists as sequential
// depths and re-renders in the new order (DG2). No CDN Sortable — the engine vendors it.

const CHART = "/teams/buffalo-bills/depth-chart";

test("depth chart renders through the studio/board primitive: grid, card + dropzone contract, no CDN Sortable", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await page.goto(CHART);
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);
  // The old CDN Sortable <script> is gone — vendored studio/sortable loads globally.
  await expect(page.locator("script[src*='sortablejs']")).toHaveCount(0);

  // DG3 — the two-level grid: Offense + Defense render as labelled group sections.
  await expect(page.locator("[data-board-group='offense']")).toHaveCount(1);
  await expect(page.locator("[data-board-group='defense']")).toHaveCount(1);

  // ZONE half — a #dropzone-<position>.kanban-dropzone per lane, keyed by position.
  const qb = page.locator("#dropzone-QB.kanban-dropzone");
  await expect(qb).toHaveAttribute("data-position", "QB");
  // CARD half — id=card-<id>, .kanban-card, data-id, data-position.
  const card = qb.locator(".kanban-card").first();
  await expect(card).toHaveAttribute("data-id", /^\d+$/);
  await expect(card).toHaveAttribute("data-position", "QB");

  expect(errors, errors.join("\n")).toHaveLength(0);
});

test("a locked starter carries .kanban-locked so the factory pins it", async ({ page }) => {
  await page.goto(CHART);
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);

  // Josh Allen (QB depth 1) is seeded locked — the top QB card is pinned.
  const topQb = page.locator("#dropzone-QB .kanban-card").first();
  await expect(topQb).toHaveClass(/kanban-locked/);
  // An unlocked lane (RB) has no pinned card.
  await expect(page.locator("#dropzone-RB .kanban-card.kanban-locked")).toHaveCount(0);
});

test("within-lane reorder persists sequential depths and re-renders in the new order", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(CHART);
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);

  // The RB lane has no locked card, so a reversal restamps cleanly to 1..N.
  const readOrder = () =>
    page.locator("#dropzone-RB .kanban-card").evaluateAll((els) => els.map((e) => e.getAttribute("data-id")));

  const before = await readOrder();
  expect(before.length).toBeGreaterThanOrEqual(2);
  const reversed = [...before].reverse();

  // Drive the same endpoint a drag saves to (Studio::Board::Reorderable) — the payload
  // key is entry_ids and the admin session cookie rides page.request.
  const resp = await page.request.post(`${CHART}/reorder`, {
    headers: { "Content-Type": "application/json" },
    data: { entry_ids: reversed },
  });
  expect(resp.ok(), await resp.text()).toBeTruthy();

  await page.reload();
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);
  expect(await readOrder()).toEqual(reversed);
});
