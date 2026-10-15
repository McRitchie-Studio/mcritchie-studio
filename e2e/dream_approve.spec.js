const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// /dreams one-click approval (DreamsController#approve). The server reads the fixture
// bank (DREAM_BANK_DIR in playwright.config.js), whose `proposed-money-idea` is
// proposed. The seeded admin is not the approver and sees no button. Alex's account
// (a parked admin identity, made on his first magic link) does, and one click turns
// the card's Proposed badge into the pending-release badge. The filter is switched
// to Proposed in place first (no reload), and the approve redirect keeps it.
test("Alex approves a proposed dream in one click; another admin cannot", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  const card = page.locator("[data-test='dream-card'][data-dream='proposed-money-idea']");

  await page.goto("/dreams");
  await card.locator("summary").click();
  await expect(card.locator("[data-test='dream-answer']")).toBeVisible();
  await expect(card.locator("[data-test='dream-approve']")).toHaveCount(0);

  await loginWithMagicLink(page, "alex@mcritchie.studio");
  await page.goto("/dreams");
  await expect(card.locator("[data-test='dream-proposed-badge']")).toHaveText("Proposed");
  await page.click("[data-test='dream-filter-proposed']");
  await expect(page).toHaveURL(/status=proposed/);
  await card.locator("summary").click();
  await expect(card.getByRole("button", { name: "Approve dream proposed-money-idea" })).toBeVisible();
  await card.locator("[data-test='dream-approve']").click();

  // Turbo follows the 303 by fetch, so the redirect's #dream- anchor may not reach the bar.
  await expect(page).toHaveURL(/\/dreams\?status=proposed(#dream-proposed-money-idea)?$/);
  await expect(page.locator("[data-test='dream-filter-proposed']")).toHaveAttribute("aria-current", "page");
  await expect(card.locator("[data-test='dream-approved-pending-badge']"))
    .toHaveText("Approved, loads after the next release");
  await expect(card.locator("[data-test='dream-proposed-badge']")).toHaveCount(0);
  await expect(card).toHaveAttribute("data-status", "proposed");
  await card.locator("summary").click();
  await expect(card.locator("[data-test='dream-approval-note']")).toBeVisible();
  await expect(card.locator("[data-test='dream-approve']")).toHaveCount(0);

  expect(pageErrors, report()).toHaveLength(0);
});
