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
