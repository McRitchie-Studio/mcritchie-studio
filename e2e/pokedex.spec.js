const { test, expect } = require("@playwright/test");

// [e2e] Public board navigation reaches the spawned-Pokemon Pokédex. This stays
// data-agnostic so it can run against local seed, QA, and production.
test("pokedex is linked from the board nav and renders @qa-readonly", async ({ page }) => {
  const board = await page.goto("/deployments");
  expect(board.ok()).toBe(true);

  const navLink = page.locator("nav[aria-label='Board sections'] a[href='/pokedex']");
  await expect(navLink).toBeVisible();
  await expect(navLink).toHaveText("Pokédex");

  await navLink.click();
  await expect(page).toHaveURL(/\/pokedex$/);
  await expect(page.locator("[data-test='pokedex']")).toBeVisible();
  await expect(page.locator("[data-test='pokedex-total']")).toBeVisible();
  await expect(page.locator("[data-test='pokemon-card']")).toBeVisible();
  await expect(page.locator("[data-test='shiny-card']")).toBeVisible();
  await expect(page.locator("[data-test='recent-pokemon-actions']")).toBeVisible();
});

// [e2e] The collection grid. Data-agnostic like the test above — it runs against local
// seed, QA, and production, so it asserts the grid's STRUCTURE (a cell per seeded
// species, every cell in a drawable state) and derives the expected count from the
// page's own dex total rather than from any fixture.
test("pokedex collection grid draws a cell per species and flips shiny @qa-readonly", async ({ page }) => {
  const response = await page.goto("/pokedex");
  expect(response.ok()).toBe(true);

  await expect(page.locator("[data-test='dex-grid']")).toBeVisible();
  await expect(page.locator("[data-test='dex-legend']")).toBeVisible();

  // One cell per species — the header's dex total is the source of truth in any env.
  const total = parseInt((await page.locator("[data-test='pokedex-total']").innerText()).replace(/\D/g, ""), 10);
  expect(total).toBeGreaterThan(0);
  const cells = page.locator("[data-test='dex-cell']");
  await expect(cells).toHaveCount(total);

  // Every cell is in a state the grid can actually draw.
  const states = await cells.evaluateAll((nodes) => nodes.map((node) => node.dataset.state));
  expect(states.every((state) => ["caught", "seen", "unseen"].includes(state))).toBe(true);

  // A revealed species flips to its shiny art on click; a silhouette is inert. Which
  // of the two an env offers depends on its data, so assert whichever it has.
  const toggles = page.locator("[data-test='dex-shiny-toggle']");
  if ((await toggles.count()) > 0) {
    const toggle = toggles.first();
    await toggle.scrollIntoViewIfNeeded();
    await expect(toggle).toHaveAttribute("aria-pressed", "false");
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-pressed", "true");
    await expect(toggle.locator("img[alt$='(shiny)']")).toBeVisible();
  } else {
    expect(states.every((state) => state === "unseen")).toBe(true);
  }
});
