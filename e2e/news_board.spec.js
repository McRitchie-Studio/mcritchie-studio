const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// The /news pipeline board, rebased onto the studio/board engine primitive. These specs
// assert the effect: the board renders through the primitive with the card/dropzone
// identity contract, the chrome-state-home focus toggle works, and a real reorder persists
// and re-renders in the new order. No CDN Sortable — the engine vendors it globally.

test("news board renders through the studio/board primitive with the card and dropzone contract", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await page.goto("/news");
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);
  // The old CDN Sortable <script> is gone — vendored studio/sortable loads it globally.
  await expect(page.locator("script[src*='sortablejs']")).toHaveCount(0);

  // ZONE half of the contract — one #dropzone-<stage>.kanban-dropzone per column.
  const zone = page.locator("#dropzone-new.kanban-dropzone");
  await expect(zone).toHaveAttribute("data-stage", "new");
  // CARD half — id=card-<slug>, .kanban-card, data-slug, data-stage.
  const card = zone.locator(".kanban-card").first();
  await expect(card).toHaveAttribute("data-slug", /^news-/);
  await expect(card).toHaveAttribute("data-stage", "new");

  expect(errors, errors.join("\n")).toHaveLength(0);
});

test("news focus label hides the other columns via the chrome-state home", async ({ page }) => {
  await page.goto("/news");
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);

  const reviewed = page.locator("[data-board-column='reviewed']");
  await expect(reviewed).toBeVisible();

  // Click the "New" column label — state.focusedStage becomes 'new', so show_expr hides
  // every other column and the sole visible one fills the row.
  await page.locator("[data-board-column='new'] h3 span").first().click();
  await expect(reviewed).toBeHidden();

  // Click again — focus clears, all columns return.
  await page.locator("[data-board-column='new'] h3 span").first().click();
  await expect(reviewed).toBeVisible();
});

test("news reorder persists and the board re-renders in the new order", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/news");
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);

  const readOrder = () =>
    page.locator("#dropzone-new .kanban-card").evaluateAll((els) => els.map((e) => e.getAttribute("data-slug")));

  const before = await readOrder();
  expect(before.length).toBeGreaterThanOrEqual(2);
  const reversed = [...before].reverse();

  // Drive the same endpoint a drag saves to (Studio::Board::Reorderable); the logged-in
  // admin session cookie rides page.request.
  const resp = await page.request.post("/news/reorder.json", {
    headers: { "Content-Type": "application/json" },
    data: { slugs: reversed },
  });
  expect(resp.ok(), await resp.text()).toBeTruthy();

  await page.reload();
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(1);
  expect(await readOrder()).toEqual(reversed);
});
