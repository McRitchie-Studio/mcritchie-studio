const { test, expect } = require("@playwright/test");

// The /deployments Last Release card wears a post-ship production smoke SEAL badge
// (🟢/🔴) — the verdict of the read-only @qa-readonly suite (bin/prod-smoke) run
// against prod after the ship's /up hard-gate. Seeded (e2e/seed.rb): the shipped
// Last Release carries a GREEN seal. Happy-path render only.
test("the Last Release card shows the production smoke-seal badge", async ({ page }) => {
  await page.goto("/deployments");

  const badge = page.locator("#last-release [data-test='release-smoke-seal-badge']");
  await expect(badge).toBeVisible();
  await expect(badge).toHaveAttribute("data-seal-status", "green");
  await expect(badge).toContainText("🟢");
  await expect(badge).toContainText("Seal");

  // The seal sits left of the consolidated state badge in the same top-right row.
  const state = page.locator("#last-release [data-test='release-state-badge']");
  await expect(state).toBeVisible();
  const seal = await badge.boundingBox();
  const shipped = await state.boundingBox();
  expect(seal.x).toBeLessThan(shipped.x);

  // The tooltip carries the full verdict line for an operator hover.
  await expect(badge).toHaveAttribute("title", /Production smoke seal: passed/);
});
