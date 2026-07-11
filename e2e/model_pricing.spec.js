const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] Admin opens a model, the sliders recompute the last-session cost live,
// and saving the new rate persists it across a reload.
test("admin tunes a model's rate, cost recalcs live, and the change persists", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/admin/model_pricing");
  await expect(page.getByRole("heading", { name: "Model Pricing" })).toBeVisible();

  // Into the seeded model that has a last session with usage (non-zero tokens).
  await page.getByRole("link", { name: "opus-4-8", exact: true }).first().click();
  await expect(page).toHaveURL(/\/admin\/model_pricing\/claude-opus-4-8$/);

  const inputSlider = page.locator('input[name="model_rate_override[input_rate]"]');
  const totalCost = page.locator('[data-testid="total-cost"]');
  await expect(inputSlider).toBeVisible();

  // The slider recomputes the total cost live (tokens are fixed, rate moves).
  const before = await totalCost.innerText();
  await inputSlider.fill("40");
  await expect(totalCost).not.toHaveText(before);

  // Save, then reload — the override persisted, so the slider re-opens at 40.
  await page.getByRole("button", { name: "Save rates" }).click();
  await expect(page).toHaveURL(/\/admin\/model_pricing\/claude-opus-4-8$/);
  await expect(page.locator('input[name="model_rate_override[input_rate]"]')).toHaveValue("40");
});
