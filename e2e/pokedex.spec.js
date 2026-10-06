const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// [e2e] The Pokédex and the board that links to it sit behind the admin wall
// (app/controllers/concerns/admin_wall.rb). @qa-readonly: bin/prod-smoke runs this
// against QA and PRODUCTION as a visitor, so it asserts the wall — the visitor is
// sent to sign-in from both, and never reaches the board nav's Pokédex link.
test.describe("pokedex admin wall", () => {
  test.use({ storageState: VISITOR });

  test("pokedex and its board nav send a visitor to sign-in @qa-readonly", async ({ page, request }) => {
    for (const path of ["/pokedex", "/deployments"]) {
      const res = await request.get(path, { maxRedirects: 0 });
      expect(res.status(), `${path} is walled`).toBe(302);
      expect(new URL(res.headers()["location"], "http://host").pathname, `${path} redirects to sign-in`).toBe("/login");

      await page.goto(path);
      expect(new URL(page.url()).pathname, `${path} lands on sign-in`).toMatch(/^\/(login|signin)$/);
      await expect(page.locator('input[name="email"]')).toBeVisible();
      await expect(page.locator("a[href='/pokedex']")).toHaveCount(0);
      await expect(page.locator("[data-test='pokedex']")).toHaveCount(0);
    }
  });
});

// [e2e] Board navigation reaches the spawned-Pokemon Pokédex, and its collection grid
// draws, as the seeded admin. Local lane only (prod-smoke has no admin session), so
// NOT @qa-readonly. Data-agnostic all the same: it asserts the grid's STRUCTURE (a
// cell per species, every cell in a drawable state) and derives the expected count
// from the page's own dex total rather than from any fixture.
test("pokedex is linked from the board nav and its grid draws a cell per species", async ({ page }) => {
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

  // The collection grid.
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
