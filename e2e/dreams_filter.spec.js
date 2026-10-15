const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// /dreams status filter (app/javascript/dreams_filter.js) — a click on Proposed
// filters the org chart IN PLACE: approved dream cards and stage groups with no
// proposed dream stop rendering (computed display), every "N dreams" label
// recounts to the filter, aria-current moves to the active control, the URL
// carries the choice, and the page was not reloaded. A dream card opens to its detail on click.
//
// The page reads the fixture bank, test/fixtures/dreams (DREAM_BANK_DIR in
// playwright.config.js), not the tracked one. The spec still counts by status
// rather than naming dreams, so a fixture added later does not break it.
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

  // Every "N dreams" label, with the count its status tokens give under `filter`.
  const counts = (filter) => page.evaluate((f) =>
    [...document.querySelectorAll("[data-dream-count]")].map((label) => {
      const tokens = label.dataset.dreamCount.split(" ").filter(Boolean);
      const n = f === "all" ? tokens.length : tokens.filter((t) => t === f).length;
      return { shown: label.textContent.trim(), expected: `${n} ${n === 1 ? "dream" : "dreams"}` };
    }), filter);

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
  await expect(page.locator("[data-test='dream-filter-proposed']")).toHaveAttribute("aria-current", "page");
  await expect(page.locator("[data-test='dream-filter-all']")).not.toHaveAttribute("aria-current", /.*/);
  const proposedCounts = await counts("proposed");
  expect(proposedCounts.length).toBeGreaterThan(0);
  for (const label of proposedCounts) expect(label.shown).toBe(label.expected);
  // The fixture bank is mostly approved, so at least one label must have dropped.
  const allCounts = await counts("all");
  expect(allCounts.some((label, i) => label.expected !== proposedCounts[i].shown)).toBe(true);
  const after = await displays();
  expect(after.filter((card) => card.shown).every((card) => card.status === "proposed")).toBe(true);
  expect(after.filter((card) => card.status === "approved").some((card) => card.shown)).toBe(false);
  expect(await page.evaluate(() => window.__noFullReload)).toBe("kept");

  await page.click("[data-test='dream-filter-all']");
  expect((await displays()).every((card) => card.shown)).toBe(true);
  for (const label of await counts("all")) expect(label.shown).toBe(label.expected);

  expect(pageErrors, report()).toHaveLength(0);
});
