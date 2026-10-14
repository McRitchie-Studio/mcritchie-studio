const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// /dreams status filter (app/javascript/dreams_filter.js) — a click on Proposed
// filters the org chart IN PLACE: approved dream cards and stage groups with no
// proposed dream stop rendering (computed display), the URL carries the choice,
// and the page was not reloaded. A dream card opens to its detail on click.
//
// The page reads the tracked dream bank, so the spec counts by status rather
// than naming a dream that a later merge could move.
test("the dreams status filter hides non-matching cards in place and a card opens", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/dreams");
  await expect(page.locator("[data-test='platform-row']")).toBeVisible();

  const displays = () => page.evaluate(() =>
    [...document.querySelectorAll("[data-test='dream-card']")].map((card) => ({
      status: card.dataset.status,
      shown: getComputedStyle(card).display !== "none",
    })));

  const before = await displays();
  expect(before.length).toBeGreaterThan(0);
  expect(before.every((card) => card.shown)).toBe(true);

  // A card opens to its answer on click (native <details>).
  const first = page.locator("[data-test='platform-row'] [data-test='dream-card']").first();
  await first.locator("summary").click();
  await expect(first).toHaveJSProperty("open", true);
  await expect(first.locator("[data-test='dream-answer']")).toBeVisible();

  await page.evaluate(() => { window.__noFullReload = "kept"; });
  await page.click("[data-test='dream-filter-proposed']");

  await expect(page).toHaveURL(/status=proposed/);
  await expect(page.locator("[data-test='dream-filter-proposed']")).toHaveAttribute("aria-pressed", "true");
  const after = await displays();
  expect(after.filter((card) => card.shown).every((card) => card.status === "proposed")).toBe(true);
  expect(after.filter((card) => card.status === "approved").some((card) => card.shown)).toBe(false);
  expect(await page.evaluate(() => window.__noFullReload)).toBe("kept");

  await page.click("[data-test='dream-filter-all']");
  expect((await displays()).every((card) => card.shown)).toBe(true);

  expect(pageErrors, report()).toHaveLength(0);
});
