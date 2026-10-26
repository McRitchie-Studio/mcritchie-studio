const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// /dreams one-click retirement (DreamsController#retire) and the loop's KPI strip.
// The server reads the fixture bank (DREAM_BANK_DIR in playwright.config.js), whose
// `untagged-habit` is approved. The seeded admin is not the approver and sees no
// Retire button; Alex McRitchie's account does, and one click turns the card's badge to
// "Retired, drops after the next release".
test("Alex McRitchie retires an approved dream in one click; another admin cannot", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  const card = page.locator("[data-test='dream-card'][data-dream='untagged-habit']");

  await page.goto("/dreams");
  await expect(page.locator("[data-test='dream-kpis'] [data-test='dream-kpi-value']")).toHaveCount(4);
  await card.locator("summary").click();
  await expect(card.locator("[data-test='dream-answer']")).toBeVisible();
  await expect(card.locator("[data-test='dream-retire']")).toHaveCount(0);

  await loginWithMagicLink(page, "alex@mcritchie.studio");
  await page.goto("/dreams");
  await card.locator("summary").click();
  await card.locator("[data-test='dream-retire']").click();

  await expect(page).toHaveURL(/\/dreams(#dream-untagged-habit)?$/);
  await expect(card.locator("[data-test='dream-retiring-badge']")).toHaveText("Retired, drops after the next release");
  await expect(card).toHaveAttribute("data-status", "approved");
  await card.locator("summary").click();
  await expect(card.locator("[data-test='dream-retirement-note']")).toBeVisible();
  await expect(card.locator("[data-test='dream-retire']")).toHaveCount(0);

  expect(pageErrors, report()).toHaveLength(0);
});
